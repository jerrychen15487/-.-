"""Optional server-only timing; removable without changing protocol/storage.

Each observation owns its timestamps, including while a response is delayed.
perf_counter_ns is local to this process, never compared to ESP32 timestamps.
"""
from collections import OrderedDict
import time
import uuid
from .protocol import Command as C


class Diagnostics:
    def __init__(self, log, *, clock=time.perf_counter_ns):
        self.log, self.clock = log, clock
        self.attempts = OrderedDict()
        self.observation = 0

    def receive(self, request):
        received = self.clock()
        key = (request.session, request.seq)
        attempt = self.attempts.pop(key, 0) + 1
        self.attempts[key] = attempt
        # This is diagnostic bookkeeping, not the receiver's transaction cache.
        if len(self.attempts) > 128:
            self.attempts.popitem(last=False)
        self.observation += 1
        result = dict(version=1, observation=self.observation,
                      session=request.session, seq=request.seq,
                      command=int(request.type), attempt=attempt,
                      received_ns=received, fault=[])
        if request.type in (C.BEGIN, C.DATA, C.COMMIT, C.PAUSE, C.DELETE) and len(request.payload) >= 16:
            result["id"] = str(uuid.UUID(bytes=request.payload[:16]))
        if request.type == C.DATA and len(request.payload) >= 20:
            result["block"] = int.from_bytes(request.payload[16:20], "little")
        return result

    def mark(self, record, name):
        record[name + "_ns"] = self.clock()

    def emit(self, record, outcome):
        result = dict(record, outcome=outcome)
        for name, start, end in (
            ("pre_handle", "received", "handle_start"),
            ("handle", "handle_start", "handle_end"),
            ("prepare", "handle_end", "ready"),
            ("ready_to_write", "ready", "write_start"),
            ("write_call", "write_start", "write_end"),
            ("receiver_total", "received", "write_end"),
        ):
            if start + "_ns" in record and end + "_ns" in record:
                result[name + "_us"] = (record[end + "_ns"] - record[start + "_ns"]) / 1000
        try:
            self.log.emit("score_diagnostic", **result)
        except OSError:
            # Additional diagnostics must not turn a completed operation into a
            # transport failure. Ordinary send/receive logging is unchanged.
            pass
