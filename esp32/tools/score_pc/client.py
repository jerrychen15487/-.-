"""Explicit-port UART client. Retries preserve the complete original request."""
import json
import secrets
import struct
import time
from datetime import datetime, timezone
from pathlib import Path

from .protocol import Command, Error, Frame, StreamDecoder, begin_payload, crc32, id_bytes, id_text, response_dict
from .simulator import validate_package


class RemoteError(RuntimeError):
    def __init__(self, response):
        self.response = response
        super().__init__(f"{Error(response['error']).name}: {response}")


class ResultUnknown(TimeoutError):
    pass


class JsonLog:
    def __init__(self, path=None):
        self.file = open(path, "a", encoding="utf-8") if path else None

    def emit(self, event: str, frame: Frame | None = None, **details):
        row = {"time": datetime.now(timezone.utc).isoformat(), "event": event, **details}
        if frame:
            raw = frame.encode()
            row.update(type=int(frame.type), session=frame.session, seq=frame.seq,
                       frame_crc=struct.unpack_from("<I", raw, len(raw)-4)[0], hex=raw.hex())
            if frame.type in (Command.ACK, Command.ERROR, Command.CHANGED):
                try:
                    row.update(response_dict(frame))
                except ValueError:
                    row["malformed_response"] = True
            elif frame.type in (Command.BEGIN, Command.DATA, Command.COMMIT, Command.PAUSE, Command.DELETE) and len(frame.payload) >= 16:
                row["id"] = id_text(frame.payload[:16])
                if frame.type == Command.DATA and len(frame.payload) >= 20:
                    row["block_index"] = struct.unpack_from("<I", frame.payload, 16)[0]
                if frame.type in (Command.BEGIN, Command.COMMIT) and len(frame.payload) >= 24:
                    row["file_crc"] = struct.unpack_from("<I", frame.payload, 20)[0]
        if self.file:
            self.file.write(json.dumps(row, ensure_ascii=False) + "\n")
            self.file.flush()
        return row

    def close(self):
        if self.file:
            self.file.close()


def open_serial(port: str):
    if not port:
        raise ValueError("an explicit --port is required; no serial device was opened")
    try:
        import serial
    except ImportError as exc:
        raise RuntimeError("pyserial is missing in this Python runtime") from exc
    link = serial.Serial(port=None, baudrate=1000000, bytesize=serial.EIGHTBITS,
                         parity=serial.PARITY_NONE, stopbits=serial.STOPBITS_ONE,
                         timeout=0.02, write_timeout=1, rtscts=False, dsrdtr=False)
    # Do not intentionally toggle the board's reset/boot signals.
    link.dtr = False
    link.rts = False
    link.port = port
    link.open()
    return link


class SerialTransport:
    def __init__(self, link, log: JsonLog):
        self.link, self.log = link, log
        self.decoder = StreamDecoder()

    def exchange(self, request: Frame, timeout: float) -> Frame:
        raw = request.encode()
        for attempt in range(1, 4):
            self.log.emit("request", request, attempt=attempt)
            if self.link.write(raw) != len(raw):
                raise ResultUnknown("short UART write; query state before deciding whether to retry")
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                chunk = self.link.read(min(max(self.link.in_waiting, 1), 2048))
                for reply in self.decoder.feed(chunk):
                    self.log.emit("receive", reply)
                    if (reply.version != 2 or reply.reserved or reply.type not in (Command.ACK, Command.ERROR)
                            or reply.session != request.session or reply.seq != request.seq
                            or not reply.payload or reply.payload[0] != request.type):
                        continue
                    try:
                        response_dict(reply)
                    except ValueError as exc:
                        if request.type in (Command.COMMIT, Command.DELETE):
                            raise ResultUnknown(f"malformed mutation response; query actual result: {exc}") from exc
                        continue
                    return reply
        raise ResultUnknown(f"no matching response after 3 sends: command={request.type:#x}; outcome unknown")


class Client:
    def __init__(self, transport, *, session: int | None = None):
        self.transport = transport
        self.session = session or secrets.randbelow(0xffffffff) + 1
        self.seq = 0
        self.caps = None

    def request(self, command: Command, payload: bytes = b"") -> dict:
        if self.seq >= 0xffffffff:
            raise RuntimeError("sequence exhausted; establish a fresh session and query state")
        self.seq += 1
        try:
            reply = self.transport.exchange(Frame(command, self.session, self.seq, payload),
                                            30.0 if command == Command.COMMIT else 5.0)
        except ResultUnknown:
            raise
        except OSError as exc:
            # A disconnect after write may happen after durable execution.
            raise ResultUnknown(f"UART I/O failed; command={command:#x} outcome unknown: {exc}") from exc
        try:
            parsed = response_dict(reply)
            if (reply.type not in (Command.ACK, Command.ERROR) or reply.session != self.session
                    or reply.seq != self.seq or parsed.get("request_type") != command):
                raise ValueError("response does not match request")
        except ValueError as exc:
            raise ResultUnknown(f"invalid response; command={command:#x} outcome unknown: {exc}") from exc
        if reply.type == Command.ERROR:
            raise RemoteError(parsed)
        return parsed

    def connect(self):
        caps = self.request(Command.CAPS)
        status = self.request(Command.STATUS)
        self.caps = caps
        return caps, status

    def list_all(self):
        for _ in range(3):
            generation, cursor, entries = 0, 0, []
            cursors, ids = {0}, set()
            try:
                for _page in range(65536):
                    page = self.request(Command.LIST, struct.pack("<IIHH", generation, cursor, 1, 0))
                    if generation and page["generation"] != generation:
                        break
                    generation = page["generation"]
                    for entry in page["entries"]:
                        if entry["id"] in ids:
                            raise RuntimeError("receiver LIST repeated a song UUID")
                        ids.add(entry["id"])
                    entries.extend(page["entries"])
                    following = page["next_cursor"]
                    if following is None:
                        return entries
                    if following in cursors:
                        raise RuntimeError("receiver LIST repeated a cursor")
                    cursors.add(following)
                    cursor = following
                else:
                    raise RuntimeError("receiver LIST exceeded 65536 pages")
            except RemoteError as exc:
                if exc.response["error"] != Error.STALE_LIST:
                    raise
        raise RuntimeError("directory changed repeatedly; query again when stable")

    def reconcile(self, song_id: str):
        """Only query after an unknown COMMIT/DELETE outcome, never replay a mutation."""
        old_session = self.session
        while self.session == old_session:
            self.session = secrets.randbelow(0xffffffff) + 1
        self.seq = 0
        try:
            self.connect()
            return next((row for row in self.list_all() if row["id"] == song_id), None)
        except (OSError, RuntimeError, ValueError) as exc:
            raise ResultUnknown(f"outcome remains unknown; reconciliation query failed, no mutation replayed: {exc}") from exc

    def delete(self, song_id: str):
        canonical = id_text(id_bytes(song_id))
        # Query before deletion to show which exact record is being removed.
        before = next((row for row in self.list_all() if row["id"] == canonical), None)
        try:
            result = self.request(Command.DELETE, id_bytes(canonical))
            if result["id"] != canonical:
                raise ResultUnknown("DELETE ACK identifies a different song; query actual result")
            return result
        except ResultUnknown:
            after = self.reconcile(canonical)
            if after is None:
                return {"id": canonical, "absent_after_query": True, "ack_received": False, "before": before}
            raise ResultUnknown(f"DELETE outcome unresolved; record still present, no DELETE replayed: {after}")

    def download(self, path: str | Path, *, title: str | None = None, progress=None):
        data = Path(path).read_bytes()
        info = validate_package(data)
        song_id = id_bytes(info["id"])
        if self.caps is None:
            raise RuntimeError("call connect before download")
        if (len(data) > self.caps["max_file_bytes"] or info["notes"] > self.caps["max_notes"]
                or info["pages"] > self.caps["max_pages"] or info["sections"] > self.caps["max_sections"]
                or not set(info["profiles"]).issubset(self.caps["profiles"])):
            raise RuntimeError("package exceeds receiver CAPS; no BEGIN sent")
        existing = next((entry for entry in self.list_all() if entry["id"] == info["id"]), None)
        if existing and existing["entry_state"] == 2:
            if (existing["total_bytes"], existing["file_crc"]) == (len(data), crc32(data)):
                return {"id": info["id"], "already_complete": True, "verified_by": "directory length/CRC"}
            raise RuntimeError("same UUID already complete with different bytes; explicitly delete before downloading")
        result = self.request(Command.BEGIN, begin_payload(song_id, len(data), crc32(data),
                                                          info["capabilities"], title if title is not None else info["title"]))
        total = (len(data) + 511)//512
        next_block = result["next_block"]
        if (result["id"] != info["id"] or result["total_blocks"] != total or not 0 <= next_block <= total
                or result["saved_bytes"] != min(next_block*512, len(data))):
            raise RuntimeError("invalid receiver BEGIN progress")
        for index in range(next_block, total):
            result = self.request(Command.DATA, song_id + struct.pack("<I", index) + data[index*512:(index+1)*512])
            if (result["id"] != info["id"] or result["total_blocks"] != total
                    or result["next_block"] != index+1 or result["saved_bytes"] != min((index+1)*512, len(data))):
                raise RuntimeError("receiver DATA progress does not match sequential transfer")
            if progress:
                progress(result)
        try:
            result = self.request(Command.COMMIT, song_id + struct.pack("<II", len(data), crc32(data)))
            if (result["id"] != info["id"] or result["file_crc"] != crc32(data)
                    or result["entry_state"] != 2):
                raise ResultUnknown("COMMIT ACK does not match song/CRC/complete state; query actual result")
            return result
        except ResultUnknown:
            found = self.reconcile(info["id"])
            if found and found["entry_state"] == 2 and (found["total_bytes"], found["file_crc"]) == (len(data), crc32(data)):
                return {**found, "ack_received": False, "verified_by": "directory after unknown COMMIT"}
            raise ResultUnknown(f"COMMIT outcome unresolved; no automatic new-session COMMIT replay: {found}")
