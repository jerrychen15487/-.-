# PSC2 / BLE v2 integration fixtures

These are software expectations, not evidence that ESP32 or FPGA passed them.
The sole field specification is the workspace's `trans/PROTOCOL.md`; BLE JSON
keys follow the shared web/ESP32 plan section 4. No firmware source is included.

- `v2-golden.json` and `../v2-vectors.test.ts`: frozen CRC, CAPS frame, NOTE,
  UUID/DATA and JSON vectors.
- `packages/`: a legal eight-section engineering package and separately invalid
  CRC, anchor, unsafe-start and flags packages. `packages/manifest.json` records
  each expected outcome. None belongs in the public catalog.
- `handoff-packages.json`: final public/engineering UUID, SHA-256, file and
  section CRC, total blocks, tail length, page bitmap CRC and black-pixel probes,
  every expanded measure rectangle, backward page jumps and full safe tables.
  Generated independently with Python `struct` and `zlib`, not the TS codec.
  Run `python tools/inspect-handoff.py --check` to compare frozen expectations.
- `scoring-vectors.json`: manually specified calibrated-time input/expected
  pairs. Defaults are from the shared FPGA plan section 5: onset ±50/100 ms,
  weights 50/20/20/10, first-release hold, pedal binary threshold 64 and the six
  initial velocity ranges. These ranges are test parameters, never PSC2 fields.
  `tools/scoring-reference.ts` checks them offline and is not part of the site.

The scoring vectors cover exact boundaries, missing targets versus missed
targets, selected/unselected/common parts, duplicate consumption, extra notes,
Combo and safe rollback. The matching helper does not simulate an entire FPGA
audio/event scheduler; expiry/Miss ordering is represented by explicit history.
Rollback hit/Miss history carries its target ID and follows that target's
retention; only extra-note history (`targetId: null`) uses the actual event tick.
Boundary vectors cover early hits, late hits/Misses and repeated rollback.
Raw SPI timestamp calibration, live key/pedal release gating, countdown, HDMI
timing and physical storage still need hardware tests.

The engineering package's first low-part note spans tick 0–4320; the scored
pedal spans 960–4800. Thus a pause at tick 4000 must return to zero even when
only the high part is selected. At tick 7680 an unscored pedal-down begins:
7680 is safe before the new action, 8000 is not a new safe point, and 8640 is
safe after pedal release and before the new note. Expected table:
`[0,4800,5760,7680,8640,9600,9920,10240]`.

Engineering pixel probes are deliberately simple: page 0 black at (8,20) and
(15,20), white at (9,20); pages 1/2/3 move these to rows 21/22/23. Staff page
route is 0→1→0 and jianpu is 2→3→2. Actual published notation is in public
packages; engineering images are coordinate targets, not performance scores.

After byte/pixel checks, integration order is Windows/Android browser → ESP32
→ persistent PC FPGA simulator, then real FPGA: interrupted tail block,
power-off resume, COMMIT/DELETE reply loss, local mode/delete/commit CHANGED,
offline selection, notation/part scoring and safe rollback. A mobile-sized
desktop browser is not an Android test. The website tests cannot prove 5 ms
event latency, synthesized audio quality or power-loss persistence.
