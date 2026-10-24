"""Real C proxy -> Python UART/SQLite -> C JSON, with the website PSC2 parser.

No serial ports, BLE hardware or website files are modified.
Build score_proxy_adapter.dll using tools/test.ps1 before running this module.
"""
import ctypes
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

TRANS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TRANS / "tools"))
from project_paths import WEBSITE
from score_pc.protocol import Command as C, Frame, crc32, decode, id_bytes
from score_pc.simulator import PackageInvalid, Simulator, validate_package


class CrossLanguageTests(unittest.TestCase):
    def setUp(self):
        self.dll = ctypes.CDLL(str(TRANS / "build-tests/score_proxy_adapter.dll"))
        for name in ("adapter_ble", "adapter_uart"):
            getattr(self.dll, name).argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32]
        for name in ("adapter_take_uart", "adapter_take_ble"):
            getattr(self.dll, name).argtypes = [ctypes.c_void_p]
            getattr(self.dll, name).restype = ctypes.c_size_t
        self.temp = tempfile.TemporaryDirectory()
        self.db = Path(self.temp.name) / "fpga.db"
        self.sim = Simulator(self.db)
        self.now, self.session, self.seq = 0, 500, 0
        self.dll.adapter_connect(1)

    def tearDown(self):
        self.sim.close()
        self.temp.cleanup()

    def take(self, target):
        data = ctypes.create_string_buffer(1044)
        n = getattr(self.dll, "adapter_take_" + target)(data)
        return data.raw[:n]

    def deliver(self, frame):
        raw = frame.encode()
        for i in range(0, len(raw), 7):
            self.dll.adapter_uart(raw[i:i+7], len(raw[i:i+7]), self.now)

    def request(self, cmd, payload=b"", *, lose=False, expected_notices=None):
        self.seq += 1
        self.now += 10
        if isinstance(payload, dict):
            payload = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
        raw = Frame(cmd, self.session, self.seq, payload).encode()
        for i in range(0, len(raw), 20):
            self.dll.adapter_ble(raw[i:i+20], len(raw[i:i+20]), self.now)
        self.assertTrue(self.dll.adapter_connected())
        downstream = decode(self.take("uart"))
        self.assertEqual((downstream.type, downstream.session, downstream.seq), (cmd, self.session, self.seq))
        if cmd == C.DATA:
            self.assertEqual(downstream.payload, payload)
        self.assertFalse(self.take("ble"), "GATT receipt must never generate a storage ACK")
        response = self.sim.handle(downstream)
        notices = self.sim.drain_notifications()
        if expected_notices is not None:
            self.assertEqual(len(notices), expected_notices)
        if lose:
            return None
        self.deliver(response)
        upstream = decode(self.take("ble"))
        self.assertEqual((upstream.session, upstream.seq), (self.session, self.seq))
        body = json.loads(upstream.payload)
        self.assertEqual(body["request_type"], cmd)
        for notice in notices:
            self.deliver(notice)
            notification = decode(self.take("ble"))
            self.assertEqual(notification.type, C.CHANGED)
            self.assertEqual((notification.session, notification.seq), (0, 0))
        return body

    def upload_package(self, raw, song, capabilities):
        blocks = (len(raw) + 511) // 512
        begin = dict(id=song, title="v2.1 跨端回归", total_bytes=len(raw),
                     file_crc=crc32(raw), capabilities=capabilities, block_bytes=512,
                     package_major=2, total_blocks=blocks)
        self.assertEqual(self.request(C.BEGIN, begin)["next_block"], 0)
        for i in range(blocks):
            ack = self.request(C.DATA, id_bytes(song) + struct.pack("<I", i) + raw[i*512:(i+1)*512])
            self.assertEqual((ack["next_block"], ack["saved_bytes"]),
                             (i+1, min(len(raw), (i+1)*512)))
        return begin

    def test_nil_package_rejected_by_real_web_parser_and_receiver(self):
        raw = bytearray((WEBSITE / "tests/fixtures/packages/engineering.pseq").read_bytes())
        info = validate_package(raw)
        raw[12:28] = bytes(16)  # Header identity is outside the section CRCs.
        raw = bytes(raw)
        with self.assertRaisesRegex(PackageInvalid, "UUID 不能为全零"):
            validate_package(raw)
        self.request(C.CAPS)
        # A valid command ID ensures this reaches final file validation, not
        # just the proxy's command identity check. Recompute the whole-file CRC.
        begin = self.upload_package(raw, info["id"], info["capabilities"])
        before = self.request(C.STATUS)
        snapshot = tuple(self.sim.db.iterdump())
        reply = self.request(C.COMMIT, {key: begin[key] for key in ("id", "total_bytes", "file_crc")},
                             expected_notices=0)
        self.assertEqual(reply["code"], 7)  # BAD_PACKAGE, not BAD_FILE_CRC.
        self.assertIsInstance(reply["code"], int)
        self.assertEqual(tuple(self.sim.db.iterdump()), snapshot)
        self.assertEqual(self.request(C.STATUS), before)
        page = self.request(C.LIST, {"generation": 0, "cursor": 0, "limit": 1})
        self.assertEqual(page["items"][0]["entry_state"], 1)
        self.assertEqual(self.sim.export_bytes(id_bytes(info["id"]), allow_partial=True), raw)

    def test_partial_commit_ownership_and_complete_idempotence(self):
        raw = (WEBSITE / "tests/fixtures/packages/engineering.pseq").read_bytes()
        info = validate_package(raw)
        self.request(C.CAPS)
        begin_a = self.upload_package(raw, info["id"], info["capabilities"])
        commit_a = {key: begin_a[key] for key in ("id", "total_bytes", "file_crc")}
        self.request(C.PAUSE, {"id": info["id"]})
        begin_b = {**begin_a, "id": "12345678-1234-5678-9abc-def012345679", "title": "B"}
        self.request(C.BEGIN, begin_b)
        before = self.request(C.STATUS)
        self.assertEqual(before["active_id"], begin_b["id"])
        snapshot = tuple(self.sim.db.iterdump())
        reply = self.request(C.COMMIT, commit_a, expected_notices=0)
        self.assertEqual(reply["code"], 1)
        self.assertEqual(tuple(self.sim.db.iterdump()), snapshot)
        self.assertEqual(self.request(C.STATUS), before)
        self.request(C.PAUSE, {"id": begin_b["id"]})
        self.assertEqual(self.request(C.BEGIN, begin_a)["next_block"], begin_a["total_blocks"])
        self.assertEqual(self.request(C.COMMIT, commit_a)["entry_state"], 2)
        self.assertEqual(self.sim.export_bytes(id_bytes(info["id"])), raw)
        self.request(C.BEGIN, begin_b)
        before = self.request(C.STATUS)
        snapshot = tuple(self.sim.db.iterdump())
        self.assertEqual(self.request(C.COMMIT, commit_a, expected_notices=0)["entry_state"], 2)
        self.assertEqual(tuple(self.sim.db.iterdump()), snapshot)
        self.assertEqual(self.request(C.STATUS), before)
        for mode in (1, 2, 3):
            self.sim.set_mode(mode)
            for notice in self.sim.drain_notifications():
                self.deliver(notice)
                self.assertEqual(decode(self.take("ble")).type, C.CHANGED)
            before = self.request(C.STATUS)
            reply = self.request(C.COMMIT, commit_a, expected_notices=0)
            self.assertEqual(reply["code"], 1)
            self.assertEqual(tuple(self.sim.db.iterdump()), snapshot)
            self.assertEqual(self.request(C.STATUS), before)

    def test_complete_resume_unknown_commit_and_delete(self):
        raw = (WEBSITE / "tests/fixtures/packages/engineering.pseq").read_bytes()
        song = "12345678-1234-5678-9abc-def012345678"
        caps = self.request(C.CAPS)
        self.assertEqual(caps["max_write"], 20)
        status = self.request(C.STATUS)
        self.assertIsNone(status["active_id"])
        self.assertIsInstance(status["free_bytes"], str)
        self.assertIsNone(self.request(C.LIST, {"generation": 0, "cursor": 0, "limit": 1})["next_cursor"])
        begin = dict(id=song, title="跨语言工程包", total_bytes=len(raw), file_crc=crc32(raw),
                     block_bytes=512, package_major=2, total_blocks=453)
        # Read capabilities from the real parser to avoid duplicating a PSC2 offset.
        from score_pc.simulator import validate_package
        begin["capabilities"] = validate_package(raw)["capabilities"]
        self.assertEqual(self.request(C.BEGIN, begin)["next_block"], 0)
        block0 = id_bytes(song) + struct.pack("<I", 0) + raw[:512]
        self.assertEqual(self.request(C.DATA, block0)["next_block"], 1)
        self.assertEqual(self.request(C.PAUSE, {"id": song})["next_block"], 1)
        self.sim.close()
        self.sim = Simulator(self.db)
        self.session, self.seq = 501, 0
        self.dll.adapter_connect(2)
        self.request(C.CAPS)
        self.assertEqual(self.request(C.BEGIN, begin)["next_block"], 1)
        for i in range(1, 453):
            ack = self.request(C.DATA, id_bytes(song) + struct.pack("<I", i) + raw[i*512:(i+1)*512])
            self.assertEqual((ack["next_block"], ack["saved_bytes"]), (i+1, min(len(raw), (i+1)*512)))
        self.request(C.COMMIT, dict(id=song, total_bytes=len(raw), file_crc=crc32(raw)), lose=True)
        self.now += 30000
        self.dll.adapter_poll(self.now)
        self.assertFalse(self.take("uart"), "ESP32 must not retry unknown COMMIT")
        page = self.request(C.LIST, {"generation": 0, "cursor": 0, "limit": 1})
        self.assertEqual(page["items"][0]["entry_state"], 2)
        self.assertEqual(self.sim.export_bytes(id_bytes(song)), raw)
        self.assertTrue(self.request(C.DELETE, {"id": song})["deleted"])
        self.assertFalse(self.request(C.DELETE, {"id": song})["deleted"])

    def test_mode_busy_error_and_changed(self):
        self.request(C.CAPS)
        self.sim.set_mode(3)
        notices = self.sim.drain_notifications()
        self.deliver(notices[-1])
        changed = json.loads(decode(self.take("ble")).payload)
        self.assertEqual(changed["mode"], 3)
        reply = self.request(C.DELETE, {"id": "12345678-1234-5678-9abc-def012345678"})
        self.assertIsInstance(reply["code"], int)
        self.assertEqual(reply["code"], 1)
        self.assertIsNone(reply["next_block"])


if __name__ == "__main__":
    unittest.main()
