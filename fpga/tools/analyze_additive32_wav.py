"""Inspect the first 32 harmonics of a sustained single-note PCM WAV.

This is measurement support, not a pass/fail certificate: DAC distortion can
also create harmonics. Compare A with P/O at matched pitch and recording gain.
"""

from __future__ import annotations

import argparse
import csv
import re
import wave
from pathlib import Path

import numpy as np


def parse_midi_ox_data1(value: str) -> int:
    """Parse MIDI-OX's hexadecimal DATA1 byte (e.g. 3C = MIDI 60)."""
    token = value.removeprefix("0x").removeprefix("0X")
    if not re.fullmatch(r"[0-9a-fA-F]{1,2}", token):
        raise argparse.ArgumentTypeError("DATA1 must be one or two hex digits, e.g. 3C")
    note = int(token, 16)
    if note > 127:
        raise argparse.ArgumentTypeError("MIDI note DATA1 must be 00..7F")
    return note


def read_pcm(path: Path, start: float, seconds: float, channel: str) -> tuple[int, np.ndarray]:
    with wave.open(str(path), "rb") as wav:
        if wav.getcomptype() != "NONE":
            raise ValueError("Only uncompressed PCM WAV is supported")
        rate, count, width = wav.getframerate(), wav.getnchannels(), wav.getsampwidth()
        if width not in (1, 2, 3, 4):
            raise ValueError(f"Unsupported PCM sample width: {width} bytes")
        first = round(start * rate)
        frames = round(seconds * rate)
        if first < 0 or frames < rate // 2 or first + frames > wav.getnframes():
            raise ValueError("Select at least 0.5 s wholly inside the WAV")
        wav.setpos(first)
        raw = wav.readframes(frames)

    if width == 1:
        samples = np.frombuffer(raw, np.uint8).astype(np.float64) - 128.0
        scale = 128.0
    elif width == 2:
        samples = np.frombuffer(raw, "<i2").astype(np.float64)
        scale = 32768.0
    elif width == 4:
        samples = np.frombuffer(raw, "<i4").astype(np.float64)
        scale = 2147483648.0
    else:
        triples = np.frombuffer(raw, np.uint8).reshape(-1, 3).astype(np.int32)
        signed = triples[:, 0] | (triples[:, 1] << 8) | (triples[:, 2] << 16)
        samples = ((signed ^ 0x800000) - 0x800000).astype(np.float64)
        scale = 8388608.0
    samples = samples.reshape(-1, count) / scale
    if channel == "mono":
        samples = samples.mean(axis=1)
    elif channel in ("left", "right"):
        index = 0 if channel == "left" else 1
        if index >= count:
            raise ValueError(f"WAV has only {count} channel(s)")
        samples = samples[:, index]
    else:
        rms = np.sqrt(np.mean(samples * samples, axis=0))
        samples = samples[:, int(np.argmax(rms))]
    if np.max(np.abs(samples)) < 1e-5:
        raise ValueError("Selected window is silent")
    return rate, samples


def analyze(rate: int, samples: np.ndarray, midi: int) -> tuple[float, list[dict[str, float | int]]]:
    if not 0 <= midi <= 127:
        raise ValueError("MIDI note must be 0..127")
    expected = 440.0 * 2.0 ** ((midi - 69) / 12.0)
    if expected * 32 >= rate / 2:
        raise ValueError("H32 reaches Nyquist; choose a lower note or higher WAV sample rate")
    centered = samples - np.mean(samples)
    window = np.hanning(len(centered))
    magnitude = np.abs(np.fft.rfft(centered * window))
    frequencies = np.fft.rfftfreq(len(centered), 1.0 / rate)
    resolution = rate / len(centered)
    fundamental_bins = np.flatnonzero((frequencies >= expected * 0.95) &
                                      (frequencies <= expected * 1.05))
    if not fundamental_bins.size:
        raise ValueError("No FFT bins near the expected fundamental")
    f0_bin = fundamental_bins[int(np.argmax(magnitude[fundamental_bins]))]
    if magnitude[f0_bin] < 1e-8:
        raise ValueError("No detectable fundamental near the requested MIDI note")
    # A half-bin error in f0 becomes a 16-bin error at H32. Interpolate the
    # Hann peak before multiplying its frequency by the harmonic number.
    delta = 0.0
    if 0 < f0_bin < len(magnitude) - 1:
        left, middle, right = np.log(np.maximum(magnitude[f0_bin - 1:f0_bin + 2], 1e-20))
        curvature = left - 2 * middle + right
        if abs(curvature) > 1e-12:
            delta = float(np.clip(0.5 * (left - right) / curvature, -0.5, 0.5))
    f0 = (f0_bin + delta) * resolution
    rows: list[dict[str, float | int]] = []
    fundamental_amplitude = float(magnitude[f0_bin])
    for harmonic in range(1, 33):
        target = f0 * harmonic
        half_width = max(2 * resolution, target * 0.001)
        nearby = np.flatnonzero(np.abs(frequencies - target) <= half_width)
        peak_bin = nearby[int(np.argmax(magnitude[nearby]))]
        peak = float(magnitude[peak_bin])
        # A separated sideband estimates the local floor, excluding the Hann
        # main lobe and remaining inside half the spacing to adjacent partials.
        inner = max(5 * resolution, 4.0)
        outer = min(max(20 * resolution, 15.0), f0 * 0.35)
        sideband = magnitude[(np.abs(frequencies - target) >= inner) &
                             (np.abs(frequencies - target) <= outer)]
        floor = float(np.median(sideband)) if sideband.size else 0.0
        relative_db = 20.0 * np.log10(max(peak, 1e-12) / fundamental_amplitude)
        above_floor_db = 20.0 * np.log10(max(peak, 1e-12) / max(floor, 1e-12))
        rows.append({"harmonic": harmonic, "target_hz": round(target, 2),
                     "peak_hz": round(float(frequencies[peak_bin]), 2),
                     "relative_db": round(float(relative_db), 1),
                     "above_floor_db": round(float(above_floor_db), 1)})
    return f0, rows


def pitch_warnings(midi: int, f0: float, rows: list[dict[str, float | int]]) -> list[str]:
    """Flag likely wrong-note analyses before harmonic rows are interpreted."""
    expected = 440.0 * 2.0 ** ((midi - 69) / 12.0)
    warnings = []
    if abs(f0 / expected - 1.0) > 0.015:
        warnings.append(f"measured f0 differs from MIDI {midi} ({expected:.2f} Hz) by "
                        f"{100 * (f0 / expected - 1.0):+.1f}%; check the played note")
    if rows[1]["relative_db"] > 24:
        warnings.append("H2 is over 24 dB stronger than H1; possible octave mismatch "
                        "or another sound in the recording")
    return warnings


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav", type=Path, help="Uncompressed PCM WAV recording")
    note_input = parser.add_mutually_exclusive_group(required=True)
    note_input.add_argument("--midi", type=int, help="Held MIDI note in decimal, e.g. 48 or 60")
    note_input.add_argument("--midi-ox", type=parse_midi_ox_data1,
                            help="MIDI-OX hexadecimal DATA1, e.g. 3C for MIDI 60")
    parser.add_argument("--start", type=float, default=1.0, help="Window start in seconds")
    parser.add_argument("--seconds", type=float, default=2.0, help="Window length in seconds")
    parser.add_argument("--channel", choices=("auto", "left", "right", "mono"), default="auto")
    parser.add_argument("--csv", type=Path, help="Optional output table path")
    args = parser.parse_args()
    midi = args.midi if args.midi is not None else args.midi_ox
    rate, samples = read_pcm(args.wav, args.start, args.seconds, args.channel)
    f0, rows = analyze(rate, samples, midi)
    print(f"MIDI={midi} (DATA1={midi:02X})  rate={rate} Hz  "
          f"window={len(samples)/rate:.3f} s  f0={f0:.2f} Hz")
    peak_sample = float(np.max(np.abs(samples)))
    print(f"recording peak={peak_sample:.3f} full scale")
    if peak_sample >= 0.98:
        print("WARNING: near clipping; lower recording gain before judging harmonics")
    for warning in pitch_warnings(midi, f0, rows):
        print(f"WARNING: {warning}; harmonic labels may be wrong")
    print("H   target Hz   peak Hz   vs H1 dB   above local floor dB")
    for row in rows:
        print(f"{row['harmonic']:2d}  {row['target_hz']:9.2f}  {row['peak_hz']:8.2f}"
              f"  {row['relative_db']:9.1f}  {row['above_floor_db']:20.1f}")
    if args.csv:
        with args.csv.open("w", newline="", encoding="utf-8-sig") as output:
            writer = csv.DictWriter(output, fieldnames=rows[0].keys())
            writer.writeheader()
            writer.writerows(rows)
        print(f"CSV: {args.csv}")
    print("Note: harmonic peaks alone do not prove 32 independent synthesis operations.")


if __name__ == "__main__":
    main()
