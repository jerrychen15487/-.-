"""Render a C4-only, 32-partial piano timbre audition (not FPGA firmware).

The relative levels and string stretch are approximate measurements from the
two user-provided loudspeaker recordings on 2026-10-17. They are not a
calibration of the piano's direct electrical output or of all 88 keys.
"""

from pathlib import Path

import numpy as np
from scipy.io import wavfile


SAMPLE_RATE = 48_000
DURATION_S = 2.5
FUNDAMENTAL_HZ = 261.626  # MIDI 60; this prototype is deliberately C4-only.
INHARMONICITY = 0.00035

# Relative to the first partial. The first 12 follow the recorded electric
# piano loosely; the remaining 20 are deliberately weak but nonzero.
PARTIAL_LEVELS = np.array(
    [1.0, .32, .22, .16, .040, .16, .050, .025,
     .15, .020, .008, .008]
    + [.006 * (12.0 / n) ** 2 for n in range(13, 33)],
    dtype=np.float64,
)


def stretched_frequency(partial: int) -> float:
    return (FUNDAMENTAL_HZ * partial *
            np.sqrt((1.0 + INHARMONICITY * partial * partial) /
                    (1.0 + INHARMONICITY)))


def render() -> np.ndarray:
    t = np.arange(round(SAMPLE_RATE * DURATION_S), dtype=np.float64) / SAMPLE_RATE
    # Separately damp upper partials after the strike; the ninth partial is
    # retained longer because it remained conspicuous in the reference clip.
    wave = np.zeros_like(t)
    for partial, level in enumerate(PARTIAL_LEVELS, start=1):
        extra_decay = (0.22 if partial <= 4 else
                       0.35 if partial in (6, 9) else
                       0.8 if partial <= 12 else 2.4)
        wave += level * np.exp(-extra_decay * t) * np.sin(
            2 * np.pi * stretched_frequency(partial) * t + .23 * partial)
    attack = 1.0 - np.exp(-t / .0025)
    body_decay = np.exp(-t / 1.8)
    release = np.exp(-np.maximum(t - 1.8, 0.0) / .09)
    wave *= attack * body_decay * release
    wave *= .72 / np.max(np.abs(wave))
    return np.round(wave * 32767).astype(np.int16)


def main() -> None:
    output = Path(__file__).resolve().parents[1] / "piano32_candidate_C4.wav"
    samples = render()
    wavfile.write(output, SAMPLE_RATE, samples)
    assert len(PARTIAL_LEVELS) == 32 and np.all(PARTIAL_LEVELS > 0)
    assert np.max(np.abs(samples.astype(np.int32))) < 32767
    assert stretched_frequency(32) < SAMPLE_RATE / 2
    print(f"Wrote {output} ({DURATION_S:.1f} s, mono 16-bit, {SAMPLE_RATE} Hz)")
    print(f"C4 fundamental {stretched_frequency(1):.2f} Hz; "
          f"partial 6 {stretched_frequency(6):.2f} Hz; "
          f"partial 9 {stretched_frequency(9):.2f} Hz")


if __name__ == "__main__":
    main()
