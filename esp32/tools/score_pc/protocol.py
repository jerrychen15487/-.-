"""Independent struct/zlib UART v2 implementation; PROTOCOL.md is authoritative."""
from dataclasses import dataclass
from enum import IntEnum
import struct
import time
import uuid
import zlib

MAX_PAYLOAD = 1024
BLOCK_BYTES = 512
MAGIC = b"\xa5\x5a"
HEADER = struct.Struct("<2sBBIIHH")
MAX_BLOCKS = (0xffffffff + BLOCK_BYTES - 1) // BLOCK_BYTES


class Command(IntEnum):
    CAPS = 0x01
    STATUS = 0x02
    LIST = 0x03
    BEGIN = 0x10
    DATA = 0x11
    COMMIT = 0x12
    PAUSE = 0x13
    DELETE = 0x14
    ACK = 0x80
    CHANGED = 0x90
    ERROR = 0xff


class Error(IntEnum):
    BUSY = 1
    NO_SPACE = 2
    UNSUPPORTED_VERSION = 3
    UNSUPPORTED_PROFILE = 4
    BAD_BLOCK = 5
    BAD_FILE_CRC = 6
    BAD_PACKAGE = 7
    STORAGE_ERROR = 8
    CONTENT_MISMATCH = 9
    NOT_FOUND = 10
    STALE_LIST = 11
    ALREADY_STORED = 12
    BAD_REQUEST = 13


def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xffffffff


def id_bytes(value: str) -> bytes:
    result = uuid.UUID(value).bytes
    if result == bytes(16):
        raise ValueError("nil UUID is reserved for STATUS with no active song")
    return result


def id_text(value: bytes) -> str:
    return str(uuid.UUID(bytes=value))


@dataclass(frozen=True)
class Frame:
    type: int
    session: int
    seq: int
    payload: bytes = b""
    version: int = 2
    reserved: int = 0

    def encode(self) -> bytes:
        if len(self.payload) > MAX_PAYLOAD:
            raise ValueError("payload exceeds 1024 bytes")
        data = HEADER.pack(MAGIC, self.version, self.type, self.session,
                           self.seq, len(self.payload), self.reserved) + self.payload
        return data + struct.pack("<I", crc32(data[2:]))


def decode(data: bytes) -> Frame:
    if len(data) < 20:
        raise ValueError("short frame")
    magic, version, cmd, session, seq, size, reserved = HEADER.unpack_from(data)
    if magic != MAGIC or size > MAX_PAYLOAD or len(data) != size + 20:
        raise ValueError("invalid frame length or magic")
    if crc32(data[2:-4]) != struct.unpack_from("<I", data, len(data)-4)[0]:
        raise ValueError("bad frame CRC")
    return Frame(cmd, session, seq, data[16:-4], version, reserved)


class StreamDecoder:
    """CRC resynchronizer; a gap of 100 ms discards an unfinished frame."""
    def __init__(self, timeout: float = 0.1):
        self.buffer = bytearray()
        self.last_at = None
        self.timeout = timeout
        self.discarded = 0

    def feed(self, data: bytes, now: float | None = None) -> list[Frame]:
        now = time.monotonic() if now is None else now
        if self.last_at is not None and now - self.last_at >= self.timeout:
            self.discarded += len(self.buffer)
            self.buffer.clear()
        if data:
            self.last_at = now
        self.buffer.extend(data)
        result = []
        while len(self.buffer) >= 2:
            start = self.buffer.find(MAGIC)
            if start < 0:
                keep = 1 if self.buffer[-1] == MAGIC[0] else 0
                self.discarded += len(self.buffer) - keep
                del self.buffer[:len(self.buffer)-keep]
                break
            if start:
                self.discarded += start
                del self.buffer[:start]
            if len(self.buffer) < 16:
                break
            size = struct.unpack_from("<H", self.buffer, 12)[0]
            if size > MAX_PAYLOAD:
                self.discarded += 1
                del self.buffer[0]
                continue
            if len(self.buffer) < size + 20:
                break
            raw = bytes(self.buffer[:size+20])
            try:
                result.append(decode(raw))
                del self.buffer[:size+20]
            except ValueError:
                self.discarded += 1
                del self.buffer[0]
        return result


def begin_payload(song_id: bytes, size: int, file_crc: int,
                  capabilities: int, title: str) -> bytes:
    if len(song_id) != 16 or song_id == bytes(16):
        raise ValueError("invalid or nil song UUID")
    encoded = title.encode("utf-8")
    return struct.pack("<16sIIHHIIHH", song_id, size, file_crc, BLOCK_BYTES,
                       2, (size + 511)//512, capabilities, len(encoded), 0) + encoded


def _check(condition, message):
    if not condition:
        raise ValueError(message)


def _song_id(value: bytes) -> str:
    _check(len(value) == 16 and value != bytes(16), "invalid or nil song UUID")
    return id_text(value)


def _title(value: bytes) -> str:
    text = value.decode("utf-8", errors="strict")
    _check(0 < len(value) <= 384 and len(text) <= 128 and not any(ord(c) < 32 for c in text),
           "invalid title")
    return text


def response_dict(frame: Frame) -> dict:
    """Validate UART v2 semantics before exposing any response as a result."""
    try:
        return _response_dict(frame)
    except (struct.error, UnicodeError) as exc:
        raise ValueError(f"malformed response: {exc}") from exc


def _response_dict(frame: Frame) -> dict:
    _check(frame.version == 2 and frame.reserved == 0 and len(frame.payload) <= MAX_PAYLOAD,
           "invalid response envelope")
    p = frame.payload
    result = {"type": frame.type, "session": frame.session, "seq": frame.seq}
    if frame.type == Command.CHANGED:
        generation, mode, phase, reserved = struct.unpack("<IBBH", p)
        _check(frame.session == frame.seq == 0 and generation > 0 and mode <= 3 and phase <= 2
               and reserved == 0, "invalid CHANGED")
        result.update(generation=generation, mode=mode, phase=phase)
        return result
    _check(0 < frame.session <= 0xffffffff and 0 < frame.seq <= 0xffffffff,
           "invalid response session/sequence")
    if frame.type == Command.ERROR:
        cmd, reserved, code, next_block = struct.unpack("<BBHI", p)
        # BAD_REQUEST can echo an unknown command, so do not reinterpret that
        # byte as an enum. The client separately matches its actual request.
        _check(reserved == 0 and 1 <= code <= 13, "invalid ERROR")
        result.update(request_type=cmd, error=code,
                      next_block=None if next_block == 0xffffffff else next_block)
        return result
    if frame.type != Command.ACK or len(p) < 4 or any(p[1:4]):
        raise ValueError("not an ACK/ERROR/CHANGED response")
    cmd, p = p[0], p[4:]
    result["request_type"] = cmd
    if cmd == Command.CAPS:
        values = struct.unpack_from("<HHHHIIIIIIHH", p)
        keys = ("uart_version", "package_major", "max_payload", "block_bytes",
                "max_file_bytes", "max_notes", "max_complete_songs", "max_partial_songs",
                "max_sections", "max_pages", "profile_count", "storage_flags")
        result.update(zip(keys, values))
        count, flags = values[-2:]
        _check(values[:4] == (2, 2, 1024, 512) and all(value > 0 for value in values[4:10])
               and count <= 32 and flags & 1 and len(p) == 36 + 2*count, "invalid CAPS")
        profiles = list(struct.unpack_from("<" + "H"*count, p, 36))
        _check(all(profile > 0 for profile in profiles) and len(set(profiles)) == count,
               "invalid CAPS profiles")
        result["profiles"] = profiles
    elif cmd == Command.STATUS:
        mode, phase, reserved, generation, free, song, next_block, total = struct.unpack("<BBHIQ16sII", p)
        idle = song == bytes(16)
        _check(mode <= 3 and phase <= 2 and reserved == 0 and generation > 0
               and next_block <= total, "invalid STATUS")
        _check(not idle or next_block == total == 0, "invalid STATUS idle progress")
        result.update(mode=mode, phase=phase, generation=generation, free_bytes=str(free),
                      active_id=None if song == bytes(16) else id_text(song),
                      next_block=next_block, total_blocks=total)
    elif cmd == Command.LIST:
        generation, cursor, count, reserved = struct.unpack_from("<IIHH", p)
        _check(generation > 0 and reserved == 0 and count <= 16 and
               (cursor == 0xffffffff or cursor > 0) and
               (count > 0 or cursor == 0xffffffff), "invalid LIST header")
        offset, entries = 12, []
        ids = set()
        for _ in range(count):
            song, state, size, file_crc, caps, next_block, total, title_len, reserved = struct.unpack_from("<16sB3xIIIIIHH", p, offset)
            _check(not any(p[offset+17:offset+20]) and reserved == 0 and state in (1, 2)
                   and size >= 64 and 1 <= caps <= 7 and total == (size+511)//512 and next_block <= total
                   and (state != 2 or next_block == total), "invalid LIST entry")
            offset += 44
            _check(offset + title_len <= len(p), "truncated LIST title")
            title = _title(p[offset:offset+title_len])
            offset += title_len
            song_text = _song_id(song)
            _check(song_text not in ids, "duplicate LIST UUID")
            ids.add(song_text)
            entries.append(dict(id=song_text, entry_state=state, total_bytes=size,
                                file_crc=file_crc, capabilities=caps, next_block=next_block,
                                total_blocks=total, title=title))
        if offset != len(p):
            raise ValueError("bad LIST length")
        result.update(generation=generation, next_cursor=None if cursor == 0xffffffff else cursor,
                      entries=entries)
    elif cmd in (Command.BEGIN, Command.DATA, Command.PAUSE):
        song, next_block, total, saved = struct.unpack("<16sIII", p)
        _check(1 <= total <= MAX_BLOCKS and next_block <= total and
               ((next_block < total and saved == next_block*512) or
                (next_block == total and saved >= 64 and (saved+511)//512 == total)),
               "invalid PROGRESS")
        result.update(id=_song_id(song), next_block=next_block, total_blocks=total, saved_bytes=saved)
    elif cmd == Command.COMMIT:
        song, file_crc, state = struct.unpack("<16sIB3x", p)
        _check(state == 2 and not any(p[21:24]), "invalid COMMIT result")
        result.update(id=_song_id(song), file_crc=file_crc, entry_state=state)
    elif cmd == Command.DELETE:
        song, deleted = struct.unpack("<16sB3x", p)
        _check(deleted in (0, 1) and not any(p[17:20]), "invalid DELETE result")
        result.update(id=_song_id(song), deleted=bool(deleted))
    else:
        raise ValueError("unknown ACK request type")
    return result
