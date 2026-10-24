"""PC persistent FPGA stand-in. SQLite durability is not physical FPGA evidence."""
from dataclasses import dataclass
from pathlib import Path
import json
import shutil
import sqlite3
import struct
import subprocess
import tempfile

from .protocol import Command, Error, Frame, crc32, id_text, response_dict

from project_paths import PROJECT, WEBSITE


class Rejected(Exception):
    def __init__(self, code: Error, next_block: int = 0xffffffff):
        self.code, self.next_block = code, next_block
        super().__init__(code.name)


class ValidatorUnavailable(RuntimeError):
    pass


class PackageInvalid(ValueError):
    pass


def _export_bytes(db, song_id: bytes, *, allow_partial: bool):
    if len(song_id) != 16 or song_id == bytes(16):
        raise ValueError("invalid or nil song UUID")
    song = db.execute("SELECT * FROM songs WHERE id=?", (song_id,)).fetchone()
    if song is None:
        raise Rejected(Error.NOT_FOUND)
    if not allow_partial and song["state"] != 2:
        raise Rejected(Error.BAD_PACKAGE)
    rows = db.execute("SELECT block_index,data FROM blocks WHERE id=? ORDER BY block_index", (song_id,)).fetchall()
    if len(rows) != song["next_block"] or any(
            row[0] != index or len(row[1]) != min(512, song["total_bytes"]-index*512)
            for index, row in enumerate(rows)):
        raise sqlite3.DatabaseError("persistent block/index/length inconsistency")
    return b"".join(bytes(row[1]) for row in rows)


class ReadOnlyLibrary:
    """Inspect an existing simulator database without DDL, PRAGMA writes or recovery."""
    _COLUMNS = {
        "settings": ("key", "value"),
        "songs": ("id", "state", "total_bytes", "file_crc", "capabilities", "total_blocks", "title", "next_block"),
        "blocks": ("id", "block_index", "data"),
    }

    def __init__(self, database):
        path = Path(database).resolve()
        if not path.is_file():
            raise ValueError("existing simulator database required; inspection never creates one")
        with path.open("rb") as source:
            header = source.read(100)
        # Our simulator always writes rollback-journal databases. Reject WAL
        # before SQLite opens it: mode=ro alone can still create WAL sidecars.
        if len(header) != 100 or header[:16] != b"SQLite format 3\0" or header[18:20] != b"\x01\x01":
            raise ValueError("not a rollback-journal simulator database; inspection will not initialize or recover it")
        self.db = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)
        self.db.row_factory = sqlite3.Row
        try:
            # All inspection/export queries refer to one consistent read snapshot.
            self.db.execute("BEGIN")
            for table, columns in self._COLUMNS.items():
                actual = tuple(row[1] for row in self.db.execute(f"PRAGMA table_info({table})"))
                if actual != columns:
                    raise ValueError(f"not a simulator database: incompatible {table} schema")
            if self.db.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                raise sqlite3.DatabaseError("database integrity check failed")
            if self.db.execute("PRAGMA foreign_key_check").fetchone() is not None:
                raise sqlite3.DatabaseError("database has orphan blocks")
            if not 1 <= self.generation <= 0xffffffff:
                raise ValueError("invalid persistent generation")
            self.records = self._read_entries()
        except Exception:
            self.db.close()
            raise

    def close(self):
        self.db.close()

    @property
    def generation(self):
        row = self.db.execute("SELECT value FROM settings WHERE key='generation'").fetchone()
        if row is None or type(row[0]) is not int:
            raise ValueError("missing or invalid persistent generation")
        return row[0]

    def _read_entries(self):
        records = []
        for row in self.db.execute("SELECT * FROM songs ORDER BY id"):
            try:
                if not isinstance(row["id"], bytes) or len(row["id"]) != 16:
                    raise ValueError("invalid persistent UUID size")
                title = row["title"].encode("utf-8")
                entry = struct.pack("<16sB3xIIIIIHH", row["id"], row["state"], row["total_bytes"],
                                    row["file_crc"], row["capabilities"], row["next_block"],
                                    row["total_blocks"], len(title), 0) + title
                payload = b"\x03\0\0\0" + struct.pack("<IIHH", self.generation, 0xffffffff, 1, 0) + entry
                validated = response_dict(Frame(Command.ACK, 1, 1, payload))["entries"][0]
            except (AttributeError, TypeError, struct.error) as exc:
                raise ValueError("invalid persistent song record") from exc
            records.append(validated)
        return records

    def export_bytes(self, song_id: bytes, *, allow_partial: bool = False):
        return _export_bytes(self.db, song_id, allow_partial=allow_partial)


def validate_package(data: bytes, *, node: str | None = None) -> dict:
    """Execute the actual web PSC2 parser. Missing dependencies fail closed."""
    node = node or shutil.which("node")
    tsx = WEBSITE / "node_modules/tsx/dist/cli.mjs"
    adapter = PROJECT / "tools/validate_psc2.ts"
    if not node or not tsx.is_file() or not adapter.is_file():
        raise ValidatorUnavailable("Node/tsx/PSC2 adapter missing; COMMIT cannot publish")
    with tempfile.TemporaryDirectory(prefix="score-validate-") as folder:
        path = Path(folder) / "input.pseq"
        path.write_bytes(data)
        try:
            run = subprocess.run([node, str(tsx), str(adapter), str(path), str(WEBSITE / "src/lib/psc2.ts")],
                                 cwd=PROJECT, capture_output=True, text=True,
                                 encoding="utf-8", timeout=25, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ValidatorUnavailable(str(exc)) from exc
        try:
            result = json.loads(run.stdout)
        except (ValueError, TypeError) as exc:
            raise ValidatorUnavailable(f"validator did not return JSON: {run.stderr[-500:]}") from exc
        if run.returncode == 2 and result.get("ok") is False:
            raise PackageInvalid(result.get("error", "invalid PSC2"))
        if run.returncode != 0 or result.get("ok") is not True:
            raise ValidatorUnavailable(f"validator failed: {run.stderr[-500:]}")
        return result


@dataclass(frozen=True)
class Limits:
    storage_bytes: int = 128 * 1024 * 1024
    max_file_bytes: int = 32 * 1024 * 1024
    max_notes: int = 100000
    max_complete_songs: int = 32
    max_partial_songs: int = 8
    max_sections: int = 128
    max_pages: int = 512
    profiles: tuple[int, ...] = (1,)

    def __post_init__(self):
        if not 0 < self.storage_bytes <= 0xffffffffffffffff:
            raise ValueError("storage_bytes must fit positive u64")
        for name in ("max_file_bytes", "max_notes", "max_complete_songs", "max_partial_songs", "max_sections", "max_pages"):
            if not 0 < getattr(self, name) <= 0xffffffff:
                raise ValueError(f"{name} must fit positive u32")
        if not self.profiles or len(self.profiles) > 32 or len(set(self.profiles)) != len(self.profiles) or any(p != 1 for p in self.profiles):
            raise ValueError("only defined profile 1 is supported")


class Simulator:
    def __init__(self, database: str | Path, *, limits: Limits = Limits(), validator=validate_package):
        self.db = sqlite3.connect(str(database))
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.execute("PRAGMA journal_mode=DELETE")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            INSERT OR IGNORE INTO settings VALUES ('generation', 1);
            CREATE TABLE IF NOT EXISTS songs (
                id BLOB PRIMARY KEY CHECK(length(id)=16),
                state INTEGER NOT NULL CHECK(state IN (1,2)),
                total_bytes INTEGER NOT NULL, file_crc INTEGER NOT NULL,
                capabilities INTEGER NOT NULL, total_blocks INTEGER NOT NULL,
                title TEXT NOT NULL, next_block INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS blocks (
                id BLOB NOT NULL REFERENCES songs(id) ON DELETE CASCADE,
                block_index INTEGER NOT NULL, data BLOB NOT NULL,
                PRIMARY KEY(id, block_index));
        """)
        self.limits, self.validator = limits, validator
        self.mode = 0
        self.active_id = None
        self.session = None
        self.retired_sessions = set()
        self.last_seq = 0
        self.last_request = self.last_response = None
        self.notifications = []
        self.last_diagnostic = None

    def close(self):
        self.db.close()

    @property
    def generation(self) -> int:
        return self.db.execute("SELECT value FROM settings WHERE key='generation'").fetchone()[0]

    def _increment_generation(self):
        # Zero remains reserved for an initial LIST request.
        self.db.execute("UPDATE settings SET value=CASE WHEN value=4294967295 THEN 1 ELSE value+1 END WHERE key='generation'")

    def _changed(self):
        self.notifications.append(Frame(Command.CHANGED, 0, 0,
                                        struct.pack("<IBBH", self.generation, self.mode,
                                                    int(self.active_id is not None), 0)))

    def drain_notifications(self) -> list[Frame]:
        result, self.notifications = self.notifications, []
        return result

    def _song(self, song: bytes):
        return self.db.execute("SELECT * FROM songs WHERE id=?", (song,)).fetchone()

    def free_bytes(self) -> int:
        # Reserve whole files on BEGIN; an unfinished task cannot overpromise space.
        reserved = self.db.execute("SELECT COALESCE(SUM(total_bytes),0) FROM songs").fetchone()[0]
        return max(0, self.limits.storage_bytes - reserved)

    def _count(self, state: int) -> int:
        return self.db.execute("SELECT COUNT(*) FROM songs WHERE state=?", (state,)).fetchone()[0]

    @staticmethod
    def _progress(song) -> bytes:
        return struct.pack("<16sIII", song["id"], song["next_block"], song["total_blocks"],
                           min(song["next_block"]*512, song["total_bytes"]))

    @staticmethod
    def _require(condition: bool, code: Error = Error.BAD_REQUEST, next_block: int = 0xffffffff):
        if not condition:
            raise Rejected(code, next_block)

    @staticmethod
    def _error(request: Frame, code: Error, next_block=0xffffffff):
        return Frame(Command.ERROR, request.session, request.seq,
                     struct.pack("<BBHI", request.type, 0, code, next_block))

    def handle(self, request: Frame) -> Frame:
        """Called only for an intact frame; storage commit precedes response creation."""
        self.last_diagnostic = None
        if request.version != 2:
            return self._error(request, Error.UNSUPPORTED_VERSION)
        if request.reserved or not request.session or not request.seq:
            return self._error(request, Error.BAD_REQUEST)
        raw = request.encode()
        if request.session != self.session:
            if (request.type != Command.CAPS or request.payload or request.seq != 1
                    or request.session in self.retired_sessions):
                return self._error(request, Error.BAD_REQUEST)
            if self.session is not None:
                self.retired_sessions.add(self.session)
            self.session, self.last_seq = request.session, 0
            self.last_request = self.last_response = None
            # The old transaction loses its owner; persisted songs are untouched.
            self.active_id = None
        if request.seq == self.last_seq:
            return self.last_response if raw == self.last_request else self._error(request, Error.BAD_REQUEST)
        if request.seq < self.last_seq:
            return self._error(request, Error.BAD_REQUEST)
        try:
            body = self._execute(request.type, request.payload)
            response = Frame(Command.ACK, request.session, request.seq, bytes([request.type, 0, 0, 0]) + body)
        except Rejected as exc:
            response = self._error(request, exc.code, exc.next_block)
        except (sqlite3.Error, OSError, ValidatorUnavailable) as exc:
            self.db.rollback()
            self.last_diagnostic = str(exc)
            response = self._error(request, Error.STORAGE_ERROR)
        self.last_seq, self.last_request, self.last_response = request.seq, raw, response
        return response

    def _execute(self, cmd: int, p: bytes) -> bytes:
        require = self._require
        if cmd in (Command.CAPS, Command.STATUS):
            require(not p)
        if cmd == Command.CAPS:
            c = self.limits
            return struct.pack("<HHHHIIIIIIHH", 2, 2, 1024, 512, c.max_file_bytes, c.max_notes,
                               c.max_complete_songs, c.max_partial_songs, c.max_sections,
                               c.max_pages, len(c.profiles), 1) + struct.pack("<" + "H"*len(c.profiles), *c.profiles)
        if cmd == Command.STATUS:
            active = self._song(self.active_id) if self.active_id else None
            return struct.pack("<BBHIQ16sII", self.mode, int(active is not None), 0,
                               self.generation, self.free_bytes(), active["id"] if active else bytes(16),
                               active["next_block"] if active else 0, active["total_blocks"] if active else 0)
        if cmd == Command.LIST:
            require(len(p) == 12)
            generation, cursor, limit, reserved = struct.unpack("<IIHH", p)
            require(reserved == 0 and 1 <= limit <= 16 and (generation != 0 or cursor == 0))
            require(generation in (0, self.generation), Error.STALE_LIST)
            songs = self.db.execute("SELECT * FROM songs ORDER BY id").fetchall()
            require(cursor <= len(songs))
            body = bytearray()
            count = 0
            for song in songs[cursor:cursor+limit]:
                title = song["title"].encode("utf-8")
                entry = struct.pack("<16sB3xIIIIIHH", song["id"], song["state"], song["total_bytes"],
                                    song["file_crc"], song["capabilities"], song["next_block"],
                                    song["total_blocks"], len(title), 0) + title
                if 4 + 12 + len(body) + len(entry) > 1024:
                    break
                body += entry
                count += 1
            following = cursor + count if cursor + count < len(songs) else 0xffffffff
            return struct.pack("<IIHH", self.generation, following, count, 0) + body
        if cmd in (Command.BEGIN, Command.DATA, Command.COMMIT, Command.DELETE):
            require(self.mode == 0, Error.BUSY)
        if cmd in (Command.BEGIN, Command.DATA, Command.COMMIT, Command.PAUSE, Command.DELETE):
            require(len(p) >= 16 and p[:16] != bytes(16))
        if cmd == Command.BEGIN:
            require(len(p) >= 40)
            song_id, size, file_crc, block, major, total, caps, title_len, reserved = struct.unpack_from("<16sIIHHIIHH", p)
            require(len(p) == 40+title_len and title_len <= 384 and reserved == 0)
            try:
                title = p[40:].decode("utf-8", errors="strict")
            except UnicodeDecodeError:
                raise Rejected(Error.BAD_REQUEST)
            # The shared protocol, web validTitle and C proxy require nonempty titles.
            require(0 < len(title) <= 128 and not any(ord(c) < 32 for c in title))
            require(major == 2, Error.UNSUPPORTED_VERSION)
            require(block == 512 and size >= 64 and total == (size+511)//512 and 0 < caps <= 7)
            require(size <= self.limits.max_file_bytes, Error.NO_SPACE)
            require(self.active_id in (None, song_id), Error.BUSY)
            song = self._song(song_id)
            if song:
                require(song["state"] != 2, Error.ALREADY_STORED)
                require((song["total_bytes"], song["file_crc"], song["total_blocks"], song["capabilities"])
                        == (size, file_crc, total, caps), Error.CONTENT_MISMATCH)
            else:
                require(self._count(1) < self.limits.max_partial_songs and size <= self.free_bytes(), Error.NO_SPACE)
                with self.db:
                    self.db.execute("INSERT INTO songs(id,state,total_bytes,file_crc,capabilities,total_blocks,title) VALUES (?,1,?,?,?,?,?)",
                                    (song_id, size, file_crc, caps, total, title))
                    self._increment_generation()
                song = self._song(song_id)
                self.active_id = song_id
                self._changed()
            self.active_id = song_id
            return self._progress(song)
        if cmd == Command.DATA:
            require(21 <= len(p) <= 532)
            song_id, index = struct.unpack_from("<16sI", p)
            data = p[20:]
            song = self._song(song_id)
            require(song is not None, Error.NOT_FOUND)
            require(song["state"] == 1 and self.active_id == song_id, Error.BUSY)
            expected = song["next_block"]
            require(index < song["total_blocks"] and index <= expected, Error.BAD_BLOCK, expected)
            require(len(data) == min(512, song["total_bytes"]-index*512), Error.BAD_BLOCK, expected)
            if index < expected:
                existing = self.db.execute("SELECT data FROM blocks WHERE id=? AND block_index=?", (song_id, index)).fetchone()
                require(existing is not None and bytes(existing[0]) == data, Error.CONTENT_MISMATCH)
            else:
                with self.db:
                    self.db.execute("INSERT INTO blocks VALUES (?,?,?)", (song_id, index, data))
                    self.db.execute("UPDATE songs SET next_block=? WHERE id=?", (index+1, song_id))
            return self._progress(self._song(song_id))
        if cmd == Command.PAUSE:
            require(len(p) == 16)
            song = self._song(p)
            require(song is not None, Error.NOT_FOUND)
            if self.active_id == p:
                self.active_id = None
            return self._progress(song)
        if cmd == Command.DELETE:
            require(len(p) == 16)
            existed = self._song(p) is not None
            if existed:
                with self.db:
                    self.db.execute("DELETE FROM songs WHERE id=?", (p,))
                    self._increment_generation()
                if self.active_id == p:
                    self.active_id = None
                self._changed()
            return struct.pack("<16sB3x", p, existed)
        if cmd == Command.COMMIT:
            require(len(p) == 24)
            song_id, size, file_crc = struct.unpack("<16sII", p)
            song = self._song(song_id)
            require(song is not None, Error.NOT_FOUND)
            require((size, file_crc) == (song["total_bytes"], song["file_crc"]), Error.CONTENT_MISMATCH)
            if song["state"] == 2:
                return struct.pack("<16sIB3x", song_id, file_crc, 2)
            require(self.active_id == song_id, Error.BUSY)
            require(song["next_block"] == song["total_blocks"], Error.BAD_BLOCK, song["next_block"])
            require(self._count(2) < self.limits.max_complete_songs, Error.NO_SPACE)
            data = self.export_bytes(song_id, allow_partial=True)
            require(len(data) == size and crc32(data) == file_crc, Error.BAD_FILE_CRC)
            try:
                info = self.validator(data)
            except PackageInvalid as exc:
                self.last_diagnostic = str(exc)
                raise Rejected(Error.BAD_PACKAGE)
            require(info["id"] == id_text(song_id) and
                    info["total_bytes"] == size and info["file_crc"] == file_crc and
                    info["capabilities"] == song["capabilities"], Error.BAD_PACKAGE)
            require(all(profile in self.limits.profiles for profile in info["profiles"]), Error.UNSUPPORTED_PROFILE)
            require(info["notes"] <= self.limits.max_notes and info["pages"] <= self.limits.max_pages
                    and info["sections"] <= self.limits.max_sections, Error.BAD_PACKAGE)
            with self.db:
                self.db.execute("UPDATE songs SET state=2 WHERE id=?", (song_id,))
                self._increment_generation()
            self.active_id = None
            self._changed()
            return struct.pack("<16sIB3x", song_id, file_crc, 2)
        raise Rejected(Error.BAD_REQUEST)

    def set_mode(self, mode: int):
        self._require(mode in (0, 1, 2, 3))
        if mode != self.mode:
            self.mode = mode
            if mode != 0:
                self.active_id = None
            self._changed()

    def local_delete(self, song_id: bytes) -> bool:
        """Local FPGA-style UI operation, serialized with UART requests by serve."""
        return bool(self._execute(Command.DELETE, song_id)[16])

    def export_bytes(self, song_id: bytes, *, allow_partial: bool = False) -> bytes:
        return _export_bytes(self.db, song_id, allow_partial=allow_partial)
