"""Regression checks for hostile replies, read-only inspection and delayed ACKs.

Only in-memory fake ports are used. No serial module or device is opened.
"""
import contextlib
import io
from pathlib import Path
import queue
import sqlite3
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "tools"))
from project_paths import WEBSITE
from score_pc.__main__ import SimulatorServer, offline
from score_pc.client import Client, JsonLog, ResultUnknown, SerialTransport
from score_pc.protocol import Command as C, Error as E, Frame, MAX_BLOCKS, begin_payload, crc32, decode, id_bytes, id_text, response_dict
from score_pc.simulator import Limits, ReadOnlyLibrary, Simulator

SONG = id_bytes("12345678-1234-5678-9abc-def012345678")
OTHER = id_bytes("22345678-1234-5678-9abc-def012345678")
DATA = bytes(range(64))


def ack(command, body):
    return Frame(C.ACK, 1, 1, bytes([command, 0, 0, 0]) + body)


def list_entry(song=SONG, *, state=1, title=b"A"):
    return struct.pack("<16sB3xIIIIIHH", song, state, 64, 1, 1, int(state == 2), 1, len(title), 0) + title


def mutate(data, offset, fmt, value):
    changed = bytearray(data)
    struct.pack_into(fmt, changed, offset, value)
    return bytes(changed)


def metadata(song, data=DATA):
    return dict(id=id_text(song), total_bytes=len(data), file_crc=crc32(data), capabilities=1,
                notes=1, pages=0, sections=4, profiles=[], title="test")


class FakePort:
    def __init__(self):
        self.incoming = bytearray()
        self.writes = []

    @property
    def in_waiting(self):
        return len(self.incoming)

    def read(self, size):
        result = bytes(self.incoming[:size])
        del self.incoming[:size]
        return result

    def write(self, data):
        self.writes.append(bytes(data))
        return len(data)

    def feed(self, frame):
        self.incoming.extend(frame.encode())


class ReplyValidationTests(unittest.TestCase):
    def test_caps_constants_capacities_and_profiles_are_checked(self):
        body = struct.pack("<HHHHIIIIIIHHH", 2, 2, 1024, 512, 1024, 10, 2, 2, 8, 4, 1, 1, 1)
        self.assertEqual(response_dict(ack(C.CAPS, body))["profiles"], [1])
        for offset, fmt, value in ((0, "<H", 1), (2, "<H", 1), (4, "<H", 1023), (6, "<H", 256),
                                   *((offset, "<I", 0) for offset in (8, 12, 16, 20, 24, 28)),
                                   (32, "<H", 33), (34, "<H", 0), (36, "<H", 0)):
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                response_dict(ack(C.CAPS, mutate(body, offset, fmt, value)))
        duplicate = mutate(body[:36], 32, "<H", 2) + b"\x01\0\x01\0"
        with self.assertRaises(ValueError):
            response_dict(ack(C.CAPS, duplicate))

    def test_status_nil_sentinel_and_activity_consistency(self):
        body = struct.pack("<BBHIQ16sII", 0, 0, 0, 1, 9007199254740993, bytes(16), 0, 0)
        result = response_dict(ack(C.STATUS, body))
        self.assertIsNone(result["active_id"])
        self.assertEqual(result["free_bytes"], "9007199254740993")
        for offset, fmt, value in ((0, "<B", 4), (1, "<B", 3), (2, "<H", 1), (4, "<I", 0),
                                   (32, "<I", 1), (36, "<I", 1)):
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                response_dict(ack(C.STATUS, mutate(body, offset, fmt, value)))
        # Do not invent phase/activity or maximum block constraints beyond C STATUS.
        response_dict(ack(C.STATUS, struct.pack("<BBHIQ16sII", 0, 0, 0, 1, 5, SONG, 0xffffffff, 0xffffffff)))
        response_dict(ack(C.STATUS, mutate(body, 1, "<B", 1)))

    def test_progress_commit_delete_reject_nil_reserved_and_invalid_values(self):
        progress = struct.pack("<16sIII", SONG, 1, 2, 512)
        for command in (C.BEGIN, C.DATA, C.PAUSE):
            self.assertEqual(response_dict(ack(command, progress))["saved_bytes"], 512)
            for body in (bytes(16)+progress[16:], mutate(progress, 16, "<I", 3),
                         mutate(progress, 20, "<I", 0), mutate(progress, 24, "<I", 511),
                         struct.pack("<16sIII", SONG, 1, 1, 63),
                         struct.pack("<16sIII", SONG, 0, MAX_BLOCKS+1, 0)):
                with self.subTest(command=command), self.assertRaises(ValueError):
                    response_dict(ack(command, body))
        for command, body, reserved in ((C.COMMIT, struct.pack("<16sIB3x", SONG, 1, 2), 21),
                                        (C.DELETE, struct.pack("<16sB3x", SONG, 1), 17)):
            self.assertEqual(response_dict(ack(command, body))["id"], id_text(SONG))
            for invalid in (bytes(16)+body[16:], mutate(body, reserved, "<B", 1)):
                with self.assertRaises(ValueError):
                    response_dict(ack(command, invalid))
        with self.assertRaises(ValueError):
            response_dict(ack(C.DELETE, struct.pack("<16sB3x", SONG, 2)))
        with self.assertRaises(ValueError):
            response_dict(ack(C.COMMIT, struct.pack("<16sIB3x", SONG, 1, 1)))

    def test_uart_list_accepts_sixteen_and_rejects_bad_entries(self):
        entries = b"".join(list_entry(index.to_bytes(16, "big")) for index in range(1, 17))
        body = struct.pack("<IIHH", 2, 0xffffffff, 16, 0) + entries
        self.assertEqual(len(response_dict(ack(C.LIST, body))["entries"]), 16)
        # Cursor is opaque to the wire decoder, not necessarily a row offset.
        self.assertEqual(response_dict(ack(C.LIST, mutate(body, 4, "<I", 1)))["next_cursor"], 1)
        for offset, fmt, value in ((0, "<I", 0), (8, "<H", 17), (10, "<H", 1),
                                   (12+16, "<B", 3), (12+17, "<B", 1), (12+20, "<I", 63),
                                   (12+28, "<I", 8), (12+32, "<I", 2), (12+36, "<I", 2),
                                   (12+42, "<H", 1)):
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                response_dict(ack(C.LIST, mutate(body, offset, fmt, value)))
        for entry in (list_entry(bytes(16)), list_entry(title=b""), list_entry(title=b"\xff"),
                      list_entry(title=b"bad\n"), list_entry(title=b"x"*129)):
            with self.assertRaises(ValueError):
                response_dict(ack(C.LIST, struct.pack("<IIHH", 1, 0xffffffff, 1, 0)+entry))
        with self.assertRaises(ValueError):
            response_dict(ack(C.LIST, struct.pack("<IIHH", 1, 0xffffffff, 2, 0)+list_entry()+list_entry()))

    def test_error_changed_and_envelope_are_checked(self):
        # An unknown request command can legitimately receive BAD_REQUEST.
        self.assertEqual(response_dict(Frame(C.ERROR, 1, 1, struct.pack("<BBHI", 0x55, 0, 13, 0xffffffff)))["error"], 13)
        error = struct.pack("<BBHI", C.DATA, 0, E.BAD_BLOCK, 1)
        for offset, fmt, value in ((1, "<B", 1), (2, "<H", 0), (2, "<H", 14)):
            with self.assertRaises(ValueError):
                response_dict(Frame(C.ERROR, 1, 1, mutate(error, offset, fmt, value)))
        self.assertEqual(response_dict(Frame(C.ERROR, 1, 1, mutate(error, 4, "<I", MAX_BLOCKS+1)))["next_block"], MAX_BLOCKS+1)
        changed = struct.pack("<IBBH", 1, 3, 0, 0)
        self.assertEqual(response_dict(Frame(C.CHANGED, 0, 0, changed))["mode"], 3)
        for offset, fmt, value in ((0, "<I", 0), (4, "<B", 4), (5, "<B", 3), (6, "<H", 1)):
            with self.assertRaises(ValueError):
                response_dict(Frame(C.CHANGED, 0, 0, mutate(changed, offset, fmt, value)))
        for frame in (Frame(C.CHANGED, 1, 0, changed), Frame(C.ERROR, 0, 1, error),
                      Frame(C.ERROR, 1, 0, error), Frame(C.ERROR, 1, 1, error, version=1),
                      Frame(C.ERROR, 1, 1, error, reserved=1)):
            with self.assertRaises(ValueError):
                response_dict(frame)

    def test_serial_mutation_malformed_ack_immediately_becomes_unknown(self):
        for command, body in ((C.DELETE, struct.pack("<16sB3x", SONG, 2)),
                              (C.COMMIT, struct.pack("<16sIB3x", SONG, 1, 1))):
            port = FakePort()
            port.feed(ack(command, body))
            with self.assertRaises(ResultUnknown):
                SerialTransport(port, JsonLog()).exchange(Frame(command, 1, 1, SONG), 5)
            self.assertEqual(len(port.writes), 1)

    def test_client_list_uses_opaque_cursors_and_detects_cycles(self):
        class Transport:
            def __init__(self, cursors):
                self.cursors, self.requests = iter(cursors), []

            def exchange(self, request, timeout):
                self.requests.append(struct.unpack_from("<I", request.payload, 4)[0])
                following = next(self.cursors)
                song = len(self.requests).to_bytes(16, "big")
                body = bytes([C.LIST, 0, 0, 0])+struct.pack("<IIHH", 1, following, 1, 0)+list_entry(song)
                return Frame(C.ACK, request.session, request.seq, body)

        transport = Transport([7, 3, 0xffffffff])
        self.assertEqual(len(Client(transport).list_all()), 3)
        self.assertEqual(transport.requests, [0, 7, 3])
        with self.assertRaisesRegex(RuntimeError, "repeated a cursor"):
            Client(Transport([7, 3, 7])).list_all()


class SimulatorRegressionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)/"receiver.db"
        self.sim = Simulator(self.path, validator=lambda data: metadata(SONG, data))
        self.seq = 0
        self.ask(C.CAPS)

    def tearDown(self):
        self.sim.close()
        self.temp.cleanup()

    def ask(self, command, payload=b""):
        self.seq += 1
        return response_dict(self.sim.handle(Frame(command, 1, self.seq, payload)))

    def begin(self, song=SONG):
        return self.ask(C.BEGIN, begin_payload(song, len(DATA), crc32(DATA), 1, "test"))

    def blocks(self, song=SONG):
        return self.ask(C.DATA, song+struct.pack("<I", 0)+DATA)

    def commit(self, song=SONG):
        return self.ask(C.COMMIT, song+struct.pack("<II", len(DATA), crc32(DATA)))

    def test_nil_requests_rejected_but_idle_status_allowed(self):
        for command, payload in ((C.BEGIN, bytes(16)+begin_payload(SONG, 64, 1, 1, "A")[16:]),
                                  (C.DATA, bytes(16)+struct.pack("<I", 0)+b"x"),
                                  (C.COMMIT, bytes(16)+struct.pack("<II", 64, 1)),
                                  (C.PAUSE, bytes(16)), (C.DELETE, bytes(16))):
            with self.subTest(command=command):
                self.assertEqual(self.ask(command, payload)["error"], E.BAD_REQUEST)
        with self.assertRaises(ValueError):
            id_bytes("00000000-0000-0000-0000-000000000000")
        self.assertIsNone(self.ask(C.STATUS)["active_id"])

    def test_complete_quota_checked_at_commit_and_delete_other_preserves_active(self):
        self.sim.limits = Limits(max_complete_songs=1)
        self.begin()
        self.blocks()
        self.assertEqual(self.commit()["entry_state"], 2)
        self.assertEqual(self.begin(OTHER)["next_block"], 0)
        self.blocks(OTHER)
        self.assertEqual(self.commit(OTHER)["error"], E.NO_SPACE)
        self.assertTrue(self.ask(C.DELETE, SONG)["deleted"])
        self.assertEqual(self.ask(C.STATUS)["active_id"], id_text(OTHER))
        self.sim.validator = lambda data: metadata(OTHER, data)
        self.assertEqual(self.commit(OTHER)["entry_state"], 2)

    def test_malformed_delete_ack_is_queried_and_not_replayed(self):
        self.begin()
        owner = self

        class Transport:
            def __init__(self):
                self.calls = []

            def exchange(self, request, timeout):
                self.calls.append(request)
                reply = owner.sim.handle(request)
                if request.type == C.DELETE:
                    return Frame(C.ACK, request.session, request.seq,
                                 bytes([C.DELETE, 0, 0, 0])+struct.pack("<16sB3x", SONG, 2))
                return reply

        transport = Transport()
        client = Client(transport, session=10)
        client.connect()
        result = client.delete(id_text(SONG))
        self.assertTrue(result["absent_after_query"])
        self.assertEqual(sum(r.type == C.DELETE for r in transport.calls), 1)

    def test_delayed_ack_does_not_block_retry_query_mode_change_or_notice(self):
        clock = SimpleNamespace(now=0.0)
        args = SimpleNamespace(delay=[(C.DATA, 1)], delay_seconds=31.0,
                               drop=[], corrupt=[], truncate=[], exit_before=[], exit_after=[])
        port, inbox = FakePort(), queue.Queue()
        server = SimulatorServer(self.sim, port, JsonLog(), args, inbox, clock=lambda: clock.now)
        port.feed(Frame(C.BEGIN, 1, 2, begin_payload(SONG, len(DATA), crc32(DATA), 1, "A")))
        server.step()
        port.writes.clear()
        data = Frame(C.DATA, 1, 3, SONG+struct.pack("<I", 0)+DATA)
        port.feed(data)
        server.step()
        self.assertEqual(self.sim._song(SONG)["next_block"], 1)
        self.assertEqual(port.writes, [])
        clock.now = 1
        port.feed(data)  # Idempotent retry is answered while the original reply is delayed.
        server.step()
        self.assertEqual(response_dict(decode(port.writes[-1]))["next_block"], 1)
        self.assertEqual(self.sim.db.execute("SELECT count(*) FROM blocks").fetchone()[0], 1)
        clock.now = 2
        inbox.put("mode 3")
        port.feed(Frame(C.STATUS, 1, 4))
        server.step()
        responses = [decode(raw) for raw in port.writes]
        self.assertTrue(any(frame.type == C.CHANGED and response_dict(frame)["mode"] == 3 for frame in responses))
        self.assertEqual(response_dict(responses[-1])["mode"], 3)
        clock.now = 30.9
        before = len(port.writes)
        server.step()
        self.assertEqual(len(port.writes), before)
        clock.now = 31
        server.step()
        self.assertEqual(decode(port.writes[-1]).seq, 3)
        self.assertEqual(len(port.writes), before+1)
        self.assertFalse(server.delayed)


class ReadOnlyInspectionTests(unittest.TestCase):
    def test_foreign_empty_and_missing_databases_are_not_initialized(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            foreign, empty, missing, wal = root/"foreign.db", root/"empty.db", root/"missing.db", root/"foreign-wal.db"
            connection = sqlite3.connect(foreign)
            connection.execute("CREATE TABLE user_data (value TEXT)")
            connection.execute("INSERT INTO user_data VALUES ('keep')")
            connection.commit()
            connection.close()
            connection = sqlite3.connect(wal)
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("CREATE TABLE user_data (value TEXT)")
            connection.commit()
            connection.close()
            empty.touch()
            for path in (foreign, empty, wal):
                before, mtime = path.read_bytes(), path.stat().st_mtime_ns
                for operation in ("inspect", "export", "verify"):
                    with self.subTest(path=path.name, operation=operation), self.assertRaises(ValueError):
                        offline(SimpleNamespace(db=path, operation=operation))
                self.assertEqual(path.read_bytes(), before)
                self.assertEqual(path.stat().st_mtime_ns, mtime)
            with self.assertRaises(ValueError):
                ReadOnlyLibrary(missing)
            self.assertFalse(missing.exists())
            self.assertEqual(set(p.name for p in root.iterdir()), {"foreign.db", "empty.db", "foreign-wal.db"})

    def test_valid_inspect_export_verify_are_read_only_and_snapshot_consistent(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            path = root/"correct.db"
            sim = Simulator(path, validator=lambda data: metadata(SONG, data))
            for seq, (command, payload) in enumerate(((C.CAPS, b""),
                    (C.BEGIN, begin_payload(SONG, 64, crc32(DATA), 1, "A")),
                    (C.DATA, SONG+struct.pack("<I", 0)+DATA),
                    (C.COMMIT, SONG+struct.pack("<II", 64, crc32(DATA)))), 1):
                self.assertEqual(sim.handle(Frame(command, 1, seq, payload)).type, C.ACK)
            sim.close()
            source = root/"source.pseq"
            source.write_bytes(DATA)
            before, mtime = path.read_bytes(), path.stat().st_mtime_ns
            with patch("score_pc.__main__.Simulator", side_effect=AssertionError("must not initialize")):
                for operation in ("inspect", "export", "verify"):
                    with contextlib.redirect_stdout(io.StringIO()):
                        offline(SimpleNamespace(db=path, operation=operation, id=id_text(SONG),
                                                allow_partial=False, file=source, output=root/"export.pseq"))
            self.assertEqual((root/"export.pseq").read_bytes(), DATA)
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(path.stat().st_mtime_ns, mtime)
            library = ReadOnlyLibrary(path)
            try:
                with self.assertRaises(sqlite3.OperationalError):
                    library.db.execute("DELETE FROM songs")
            finally:
                library.close()


if __name__ == "__main__":
    unittest.main()
