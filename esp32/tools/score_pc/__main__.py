"""Run with: python -m score_pc (working directory trans/tools)."""
import argparse
from collections import Counter
import heapq
import json
import os
from pathlib import Path
import queue
import sqlite3
import sys
import threading
import time

from .client import Client, JsonLog, SerialTransport, open_serial
from .protocol import Command, Frame, StreamDecoder, crc32, id_bytes, response_dict
from .simulator import Limits, ReadOnlyLibrary, Rejected, Simulator


def _print(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def fault_spec(text: str):
    """COMMAND:N selects the Nth matching response; ANY:N counts every request."""
    try:
        command, occurrence = text.upper().split(":")
        cmd = None if command == "ANY" else int(Command[command])
        count = int(occurrence)
        if count < 1:
            raise ValueError()
        return cmd, count
    except (ValueError, KeyError):
        raise argparse.ArgumentTypeError("use COMMAND:N, e.g. DATA:2 or ANY:1")


class SimulatorServer:
    """One serialized receiver with delayed replies, not delayed request processing."""
    def __init__(self, sim, link, log, args, inbox, *, clock=time.monotonic, exit_process=os._exit, diagnostic_clock=None):
        if args.delay_seconds < 0 or not args.delay_seconds < float("inf"):
            raise ValueError("delay must be finite and nonnegative")
        self.sim, self.link, self.log, self.args, self.inbox = sim, link, log, args, inbox
        self.clock, self.exit_process = clock, exit_process
        self.decoder, self.counts = StreamDecoder(), Counter()
        self.delayed = []
        self.order = 0
        self.diag = None
        if getattr(args, "diagnostics", False):
            from .diagnostics import Diagnostics
            self.diag = Diagnostics(log, **({"clock": diagnostic_clock} if diagnostic_clock else {}))

    def matches(self, specs, request):
        return any(self.counts[cmd] == occurrence for cmd, occurrence in specs if cmd in (None, request.type))

    def send(self, reply, raw=None, diagnostic=None):
        raw = reply.encode() if raw is None else raw
        if diagnostic is not None:
            self.diag.mark(diagnostic, "write_start")
        try:
            written = self.link.write(raw)
            if diagnostic is not None:
                self.diag.mark(diagnostic, "write_end")
            if written != len(raw):
                raise OSError("short simulator UART write")
        except OSError:
            if diagnostic is not None:
                self.diag.emit(diagnostic, "write_error")
            raise
        self.log.emit("send", reply, wire_hex=raw.hex())
        if diagnostic is not None:
            self.diag.emit(diagnostic, "write_returned")

    def flush_due(self):
        while self.delayed and self.delayed[0][0] <= self.clock():
            _, _, response, raw, diagnostic = heapq.heappop(self.delayed)
            self.send(response, raw, diagnostic)

    def local_control(self, local):
        parts = local.split()
        if parts == ["quit"]:
            return False
        if len(parts) == 2 and parts[0] == "mode":
            self.sim.set_mode(int(parts[1]))
        elif len(parts) == 2 and parts[0] == "delete":
            self.sim.local_delete(id_bytes(parts[1]))
        elif parts == ["status"]:
            decoded = response_dict(Frame(Command.ACK, 1, 1, b"\x02\0\0\0" + self.sim._execute(Command.STATUS, b"")))
            _print({key: value for key, value in decoded.items() if key not in ("type", "session", "seq", "request_type")})
        else:
            raise ValueError("commands: mode 0|1|2|3, delete UUID, status, quit")
        self.log.emit("local_control", command=local)
        return True

    def step(self):
        try:
            local = self.inbox.get_nowait()
        except queue.Empty:
            local = None
        if local:
            try:
                if not self.local_control(local):
                    return False
            except (ValueError, Rejected, sqlite3.Error) as exc:
                _print({"event": "local_error", "error": str(exc)})
        for notice in self.sim.drain_notifications():
            self.send(notice)
        self.flush_due()
        chunk = self.link.read(min(max(self.link.in_waiting, 1), 2048))
        for request in self.decoder.feed(chunk, now=self.clock()):
            diagnostic = self.diag.receive(request) if self.diag else None
            self.log.emit("receive", request)
            self.counts[None] += 1
            self.counts[request.type] += 1
            if self.matches(self.args.exit_before, request):
                self.log.emit("fault_exit_before", request)
                if diagnostic is not None:
                    diagnostic["fault"].append("exit_before")
                    self.diag.emit(diagnostic, "exit_before")
                self.exit_process(70)
            if diagnostic is not None:
                self.diag.mark(diagnostic, "handle_start")
            response = self.sim.handle(request)
            if diagnostic is not None:
                self.diag.mark(diagnostic, "handle_end")
                diagnostic["response_type"] = int(response.type)
                if response.type == Command.ERROR and len(response.payload) == 8:
                    diagnostic["error_code"] = int.from_bytes(response.payload[2:4], "little")
            if self.sim.last_diagnostic:
                self.log.emit("receiver_diagnostic", detail=self.sim.last_diagnostic)
            if self.matches(self.args.exit_after, request):
                self.log.emit("fault_exit_after_persist_before_reply", request)
                if diagnostic is not None:
                    diagnostic["fault"].append("exit_after")
                    self.diag.emit(diagnostic, "exit_after_persist")
                self.exit_process(71)
            raw = response.encode()
            if diagnostic is not None:
                self.diag.mark(diagnostic, "ready")
            if self.matches(self.args.drop, request):
                self.log.emit("fault_drop_reply", response)
                if diagnostic is not None:
                    diagnostic["fault"].append("drop")
                    self.diag.emit(diagnostic, "dropped")
            else:
                if self.matches(self.args.corrupt, request):
                    if diagnostic is not None: diagnostic["fault"].append("corrupt")
                    raw = raw[:-1] + bytes([raw[-1] ^ 1])
                    self.log.emit("fault_corrupt_reply", wire_hex=raw.hex())
                if self.matches(self.args.truncate, request):
                    if diagnostic is not None: diagnostic["fault"].append("truncate")
                    raw = raw[:len(raw)//2]
                    self.log.emit("fault_truncate_reply", wire_hex=raw.hex())
                if self.matches(self.args.delay, request):
                    self.log.emit("fault_delay_reply", response, seconds=self.args.delay_seconds)
                    if diagnostic is not None:
                        diagnostic["fault"].append("delay")
                        diagnostic["injected_delay_seconds"] = self.args.delay_seconds
                        self.diag.emit(diagnostic, "delay_scheduled")
                    self.order += 1
                    heapq.heappush(self.delayed, (self.clock()+self.args.delay_seconds, self.order, response, raw, diagnostic))
                else:
                    self.send(response, raw, diagnostic)
            for notice in self.sim.drain_notifications():
                self.send(notice)
        self.flush_due()
        return True


def serve(args):
    limits = Limits(storage_bytes=args.storage_bytes, max_file_bytes=args.max_file_bytes,
                    max_complete_songs=args.max_complete_songs, max_partial_songs=args.max_partial_songs,
                    max_notes=args.max_notes, max_sections=args.max_sections, max_pages=args.max_pages)
    sim = Simulator(args.db, limits=limits)
    log = JsonLog(args.log)
    link = open_serial(args.port)
    inbox = queue.Queue()

    def read_commands():
        for line in sys.stdin:
            inbox.put(line.strip())

    if args.stdin_control:
        threading.Thread(target=read_commands, daemon=True).start()
    _print({"event": "ready", "port": args.port, "baud": 1000000, "database": str(Path(args.db).resolve()),
            "note": "PC simulation only; not FPGA power-loss evidence"})
    try:
        server = SimulatorServer(sim, link, log, args, inbox)
        while server.step():
            pass
    except KeyboardInterrupt:
        pass
    finally:
        link.close()
        sim.close()
        log.close()


def client(args):
    log = JsonLog(args.log)
    link = open_serial(args.port)
    peer = Client(SerialTransport(link, log))
    try:
        caps, status = peer.connect()
        if args.operation == "caps":
            result = caps
        elif args.operation == "status":
            result = status
        elif args.operation == "list":
            result = peer.list_all()
        elif args.operation in ("download", "resume"):
            result = peer.download(args.file, title=args.title,
                                   progress=lambda value: log.emit("progress", **value))
        elif args.operation == "pause":
            result = peer.request(Command.PAUSE, id_bytes(args.id))
        elif args.operation == "delete":
            result = peer.delete(args.id)
        else:
            raise ValueError("unsupported client command")
        _print(result)
        log.emit("result", result=result)
    finally:
        link.close()
        log.close()


def offline(args):
    library = ReadOnlyLibrary(args.db)
    try:
        if args.operation == "inspect":
            result = {"generation": library.generation, "entries": library.records}
        else:
            data = library.export_bytes(id_bytes(args.id), allow_partial=args.allow_partial)
            if args.operation == "export":
                output = Path(args.output)
                with output.open("xb") as target:
                    target.write(data)
                result = {"output": str(output.resolve()), "total_bytes": len(data), "file_crc": crc32(data)}
            else:
                reference = Path(args.file).read_bytes()
                if reference != data:
                    raise ValueError(f"byte mismatch: stored={len(data)}/{crc32(data):08x}, reference={len(reference)}/{crc32(reference):08x}")
                result = {"verified": True, "comparison": "all bytes", "total_bytes": len(data), "file_crc": crc32(data)}
        _print(result)
    finally:
        library.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description="UART v2 PC tools; no port opens without explicit --port")
    sub = parser.add_subparsers(dest="command", required=True)
    server = sub.add_parser("serve", help="FPGA simulator on a user-selected data serial port")
    server.add_argument("--port", required=True)
    server.add_argument("--db", required=True)
    server.add_argument("--log", required=True)
    for name in ("storage_bytes", "max_file_bytes", "max_complete_songs", "max_partial_songs", "max_notes", "max_sections", "max_pages"):
        server.add_argument("--" + name.replace("_", "-"), type=int, default=getattr(Limits(), name))
    server.add_argument("--stdin-control", action="store_true")
    server.add_argument("--diagnostics", action="store_true", help="optional monotonic stage timings in --log; no storage changes")
    for name in ("drop", "delay", "corrupt", "truncate", "exit-before", "exit-after"):
        server.add_argument("--" + name, type=fault_spec, action="append", default=[], metavar="COMMAND:N")
    server.add_argument("--delay-seconds", type=float, default=6.0)
    server.set_defaults(run=serve)
    cli = sub.add_parser("client", help="UART test client; do not use the UART0 log port")
    cli.add_argument("--port", required=True)
    cli.add_argument("--log", required=True)
    commands = cli.add_subparsers(dest="operation", required=True)
    for name in ("caps", "status", "list"):
        commands.add_parser(name)
    for name in ("download", "resume"):
        command = commands.add_parser(name)
        command.add_argument("file")
        command.add_argument("--title")
    for name in ("pause", "delete"):
        commands.add_parser(name).add_argument("id")
    cli.set_defaults(run=client)
    for name in ("inspect", "export", "verify"):
        command = sub.add_parser(name, help="offline SQLite inspection; opens no serial port")
        command.add_argument("--db", required=True)
        if name != "inspect":
            command.add_argument("--id", required=True)
            command.add_argument("--allow-partial", action="store_true")
            command.add_argument("--output" if name == "export" else "--file", required=True)
        command.set_defaults(run=offline, operation=name)
    args = parser.parse_args(argv)
    try:
        args.run(args)
        return 0
    except (ValueError, RuntimeError, OSError, sqlite3.Error, Rejected) as exc:
        _print({"event": "error", "error": str(exc)})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
