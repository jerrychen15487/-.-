"""Check 32 partial peaks in samples captured from piano32_poly_synth RTL.

This is digital simulation evidence, not an analog DAC/room measurement.
Run the capture testbench first and pass its text output as the only argument.
"""

import math
import re
import statistics
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src" / "piano32_poly_synth.v"
SAMPLE_RATE = 50_000_000 / 1024
PHASE_STEP = 23_012_828  # MIDI 60 from the capture testbench


def magnitude(samples: list[float], frequency: float) -> float:
    omega = 2 * math.pi * frequency / SAMPLE_RATE
    real = imag = 0.0
    for index, value in enumerate(samples):
        angle = omega * index
        real += value * math.cos(angle)
        imag -= value * math.sin(angle)
    return 2 * math.hypot(real, imag) / sum(
        0.5 - 0.5 * math.cos(2 * math.pi * i / (len(samples) - 1))
        for i in range(len(samples))
    )


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: analyze_piano32_hdl_spectrum.py <captured-samples.txt>")
        return 2
    raw = Path(sys.argv[1]).read_text(encoding="ascii").splitlines()
    data = [int(line) for line in raw]
    if len(data) != 4096:
        raise ValueError(f"expected 4096 samples, got {len(data)}")
    windowed = [
        sample * (0.5 - 0.5 * math.cos(2 * math.pi * i / (len(data) - 1)))
        for i, sample in enumerate(data)
    ]
    source = SOURCE.read_text(encoding="utf-8")
    multipliers = {
        int(n): int(value)
        for n, value in re.findall(
            r"6'd(\d+): harmonic_multiplier=22'd(\d+);", source
        )
    }
    if len(multipliers) != 31 or "default: harmonic_multiplier=22'd2443812" not in source:
        raise ValueError("RTL harmonic multiplier table changed; update analyzer")
    multipliers[32] = 2_443_812
    failures = []
    print("partial  predicted_Hz  amplitude_LSB  local_floor_LSB  peak/floor")
    for partial in range(1, 33):
        frequency = (
            PHASE_STEP * multipliers[partial] / 65536
            * SAMPLE_RATE / 2**32
        )
        peak = magnitude(windowed, frequency)
        floor = statistics.median(
            magnitude(windowed, frequency + offset)
            for offset in (-85, -65, 65, 85)
        )
        ratio = peak / max(floor, 1e-9)
        print(f"{partial:7d} {frequency:13.2f} {peak:14.2f} "
              f"{floor:16.2f} {ratio:11.1f}")
        if ratio < 3 or peak < 0.7:
            failures.append(partial)
    if failures:
        print(f"FAIL: no reliable digital peak for partials {failures}")
        return 1
    print("PASS: all 32 expected digital partials rise above the local floor")
    return 0


if __name__ == "__main__":
    sys.exit(main())
