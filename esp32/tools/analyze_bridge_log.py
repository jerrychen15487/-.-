"""Summarize the last successfully enumerated USB-MIDI boot in an IDF log.

The new USB Note On line measures callback-to-SPI-completion. The older bridge
maximum also includes local joystick events. Counters are cumulative within
one boot; this tool does not claim end-to-end latency.
"""

import argparse
import re
from pathlib import Path


FIELDS = ("in", "sent", "skip", "invalid", "full", "cancel", "usb_err",
          "spi_err", "peak", "max_us", "over_5ms", "sessions", "span_ms")
BOOT = re.compile(r"ESP-ROM:esp32s3-")
MIDI_READY = re.compile(r"midi_usb: address=\d+")
BRIDGE = re.compile(r"bridge: in=\d+ sent=\d+")
NOTE_ON = re.compile(r"bridge: usb_note_on n=\d+")
PAIR = re.compile(r"([a-z0-9_]+)=(\d+)")


def parse(text: str) -> dict:
    boots = []
    current = None
    previous_rom = False
    for line in text.splitlines():
        is_rom = bool(BOOT.search(line))
        if is_rom and not previous_rom:
            if current is not None:
                boots.append(current)
            current = {"ready": False, "samples": [], "note_on": []}
        previous_rom = is_rom
        if current is None:
            if not (MIDI_READY.search(line) or BRIDGE.search(line) or NOTE_ON.search(line)):
                continue
            current = {"ready": False, "samples": [], "note_on": []}
        if MIDI_READY.search(line):
            current["ready"] = True
        if BRIDGE.search(line):
            values = {key: int(value) for key, value in PAIR.findall(line)}
            if all(field in values for field in FIELDS):
                current["samples"].append(values)
        if NOTE_ON.search(line):
            values = {key: int(value) for key, value in PAIR.findall(line)}
            if all(field in values for field in
                   ("n", "min_us", "mean_us", "max_us", "jitter_us", "over_5ms")):
                current["note_on"].append(values)
    if current is not None:
        boots.append(current)
    ready = [boot for boot in boots if boot["ready"] and boot["samples"]]
    if not ready:
        raise ValueError("No complete bridge summary after USB-MIDI enumeration")
    selected = ready[-1]
    # A monitor may start mid-boot or counters may reset without a ROM line.
    # Preserve only the final monotonic counter segment.
    samples = selected["samples"]
    start = 0
    for index in range(1, len(samples)):
        if any(samples[index][key] < samples[index - 1][key]
               for key in ("in", "sent", "full", "usb_err", "spi_err")):
            start = index
    samples = samples[start:]
    note_on = selected["note_on"]
    return {"boot_count": len(boots), "sample_count": len(samples),
            "first": samples[0], "last": samples[-1],
            "note_on": note_on[-1] if note_on else None}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, help="Saved IDF monitor text log")
    args = parser.parse_args()
    try:
        result = parse(args.log.read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    first, last = result["first"], result["last"]
    boot_word = "boot" if result["boot_count"] == 1 else "boots"
    print(f"USB-MIDI enumerated; {result['sample_count']} complete bridge summaries "
          f"in selected boot (of {result['boot_count']} observed {boot_word}).")
    print(f"Final cumulative: in={last['in']} sent={last['sent']} "
          f"max_us={last['max_us']} over_5ms={last['over_5ms']} "
          f"peak={last['peak']}")
    print("Final cumulative errors: " + " ".join(
        f"{key}={last[key]}" for key in
        ("skip", "invalid", "full", "cancel", "usb_err", "spi_err")))
    if result["sample_count"] > 1:
        print(f"Observed interval: accepted +{last['in'] - first['in']}, "
              f"sent +{last['sent'] - first['sent']}, "
              f"over_5ms +{last['over_5ms'] - first['over_5ms']}")
    note_on = result["note_on"]
    if note_on:
        print("USB Note On cumulative: " + " ".join(
            f"{key}={note_on[key]}" for key in
            ("n", "min_us", "mean_us", "max_us", "jitter_us", "over_5ms")))
    else:
        print("USB Note On statistics unavailable: log is from older firmware.")
    print("Scope: USB callback entry -> successful SPI transmit return; "
          "not keypress -> DAC analog output.")
    print("The original bridge max_us includes locally generated joystick "
          "events; usb_note_on is limited to USB Note On messages.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
