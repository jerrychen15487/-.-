"""Diagnostic on/off equivalence with fake ports and real temporary SQLite."""
import copy
from pathlib import Path
import queue
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from score_pc.__main__ import SimulatorServer
from score_pc.diagnostics import Diagnostics
from score_pc.protocol import Command as C, Frame, begin_payload, crc32, id_bytes, id_text
from score_pc.simulator import Simulator

SONG = id_bytes("12345678-1234-5678-9abc-def012345678")
DATA = bytes(range(64))


class Log:
    def __init__(self):
        self.rows = []

    def emit(self, event, frame=None, **values):
        self.rows.append(copy.deepcopy(dict(event=event, **values)))


class Port:
    def __init__(self):
        self.incoming = bytearray()
        self.writes = []

    @property
    def in_waiting(self):
        return len(self.incoming)

    def read(self, count):
        result = bytes(self.incoming[:count])
        del self.incoming[:count]
        return result

    def write(self, data):
        self.writes.append(bytes(data))
        return len(data)


def metadata(data):
    return dict(id=id_text(SONG), total_bytes=len(data), file_crc=crc32(data),
                capabilities=1, notes=1, pages=0, sections=4, profiles=[])


class DiagnosticTests(unittest.TestCase):
    def run_scenario(self, enabled, fault=None, command=C.DATA):
        args = SimpleNamespace(diagnostics=enabled, delay_seconds=6,
                               drop=[], delay=[], corrupt=[], truncate=[], exit_before=[], exit_after=[])
        if fault:
            setattr(args, fault, [(command, 1)])
        log, port = Log(), Port()
        clock = SimpleNamespace(seconds=0, ns=0, calls=0)

        def ticks():
            clock.ns += 1000
            clock.calls += 1
            return clock.ns

        with tempfile.TemporaryDirectory() as folder:
            sim = Simulator(Path(folder)/"test.db", validator=metadata)
            server = SimulatorServer(sim, port, log, args, queue.Queue(),
                                     clock=lambda: clock.seconds, diagnostic_clock=ticks)
            requests = [Frame(C.CAPS, 1, 1),
                        Frame(C.BEGIN, 1, 2, begin_payload(SONG,64,crc32(DATA),1,"test")),
                        Frame(C.DATA, 1, 3, SONG+struct.pack("<I",0)+DATA),
                        Frame(C.DATA, 1, 3, SONG+struct.pack("<I",0)+DATA),
                        Frame(C.COMMIT, 1, 4, SONG+struct.pack("<II",64,crc32(DATA))),
                        Frame(C.STATUS, 1, 5),
                        Frame(C.DELETE, 1, 6, SONG),
                        Frame(C.LIST, 1, 7, struct.pack("<IIH2x",0,0,1))]
            try:
                for request in requests:
                    port.incoming.extend(request.encode())
                    server.step()
                clock.seconds=10
                clock.ns += 10_000_000_000
                server.step()
                dump = list(sim.db.iterdump())
            finally:
                sim.close()
        return port.writes, dump, [r for r in log.rows if r["event"]=="score_diagnostic"], clock.calls

    def test_on_off_bytes_and_durable_state_identical(self):
        for fault, command in ((None,C.DATA),("drop",C.DATA),("delay",C.DATA),
                               ("corrupt",C.DATA),("truncate",C.DATA),
                               ("drop",C.COMMIT),("drop",C.DELETE)):
            with self.subTest(fault=fault, command=command):
                off = self.run_scenario(False,fault,command)
                on = self.run_scenario(True,fault,command)
                self.assertEqual(off[:2],on[:2])
                self.assertEqual(off[2:],([],0))
                self.assertTrue(on[2])
                self.assertGreater(on[3],0)

    def test_monotonic_timings_and_repeat_attempt(self):
        _, _, rows, _ = self.run_scenario(True)
        data = [r for r in rows if r["command"]==C.DATA]
        self.assertEqual([r["attempt"] for r in data],[1,2])
        for r in data:
            self.assertEqual(r["version"],1)
            self.assertEqual(r["block"],0)
            self.assertEqual(r["id"],id_text(SONG))
            for key in ("pre_handle_us","handle_us","prepare_us","ready_to_write_us","write_call_us"):
                self.assertEqual(r[key],1)
        self.assertTrue(any(r["command"]==C.COMMIT for r in rows))

    def test_delayed_original_keeps_identity_after_retry_and_queries(self):
        _, _, rows, _ = self.run_scenario(True,"delay")
        completed = [r for r in rows if r["command"]==C.DATA and r["outcome"]=="write_returned"]
        self.assertEqual([r["attempt"] for r in completed],[2,1])
        self.assertGreater(completed[-1]["ready_to_write_us"],10_000_000)
        self.assertEqual(completed[-1]["fault"],["delay"])
        self.assertEqual(completed[-1]["handle_us"],1)

    def test_short_invalid_payload_is_observable_without_exception(self):
        diag = Diagnostics(Log(),clock=lambda: 0)
        for size in range(21):
            record = diag.receive(Frame(C.DATA,1,1,bytes(size)))
            diag.emit(record,"test")
        self.assertLessEqual(len(diag.attempts),128)

    def test_optional_log_failure_does_not_raise(self):
        class Broken:
            def emit(self,*args,**kwargs):
                raise OSError("disk full")
        diag = Diagnostics(Broken())
        diag.emit(diag.receive(Frame(C.STATUS,1,1)),"test")

    def test_crash_fault_records_persistence_boundary(self):
        for phase, expected in (("exit_before",False),("exit_after",True)):
            with tempfile.TemporaryDirectory() as folder:
                sim = Simulator(Path(folder)/"test.db",validator=metadata)
                sim.handle(Frame(C.CAPS,1,1))
                sim.handle(Frame(C.BEGIN,1,2,begin_payload(SONG,64,crc32(DATA),1,"test")))
                sim.drain_notifications()
                args = SimpleNamespace(diagnostics=True,delay_seconds=6,drop=[],delay=[],corrupt=[],
                                       truncate=[],exit_before=[],exit_after=[])
                setattr(args,phase,[(C.DATA,1)])
                port, log = Port(), Log()
                def exit_process(code):
                    raise SystemExit(code)
                server = SimulatorServer(sim,port,log,args,queue.Queue(),exit_process=exit_process)
                port.incoming.extend(Frame(C.DATA,1,3,SONG+struct.pack("<I",0)+DATA).encode())
                try:
                    with self.assertRaises(SystemExit): server.step()
                    self.assertEqual(sim._song(SONG)["next_block"],int(expected))
                    self.assertEqual(port.writes,[])
                    row = [r for r in log.rows if r["event"]=="score_diagnostic"][-1]
                    self.assertEqual(row["fault"],[phase])
                finally:
                    sim.close()


if __name__ == "__main__":
    unittest.main()
