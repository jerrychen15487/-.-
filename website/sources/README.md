# Selected public-domain editions

The original files under `mutopia/` are immutable source snapshots. `manifest.json`
records their public URLs, edition identifiers, licenses and SHA-256 digests.
The composition and Mutopia typesetting are marked Public Domain by the source.

Selected complete works: Burgmüller Op.100 Nos. **5, 6 and 2**. No.7 was rejected:
its upper internal voices contain simultaneous same pitches with different
durations. The package's strict overlap rule was not changed to accommodate it.
No.2 replaces it and contains no such overlaps.

`*.events.json` is an auditable notation intermediate obtained directly from
LilyPond events, including pitch spelling, rational durations, source part,
rests, ties, articulations, dynamics and fingerings. MIDI files produced as a
LilyPond side effect are never used as a semantic source.

Printed measures and shared playback routes:

| Work | Printed measures | Route (inclusive ranges) | Expanded measures |
|---|---:|---|---:|
| No.5 | 17 | 1–8, 1–7, 9, 10–17, 10–17 | 32 |
| No.6 | 16 | 1–8, 1–8, 9–16, 1–8; stop at Fine | 32 |
| No.2 | 33 | 1–10, 3–9, 11, 12–27, 12–26, 28–33 | 55 |

Default quarter-note BPM values (112, 132, 152) come from each edition's MIDI
tempo declaration. They are not claimed to be the composer's authoritative
metronome markings. Playback uses one fixed tempo, including written rallentando
and fermata passages. Their marks remain on the score.

All three lack pedal references: pedal scoring is unavailable. Dynamics inherit
within the written part; hairpins, text cresc./dim. and unsupported dynamics
disable dynamic scoring until the next explicit supported level. Accented
attacks also have no numerical dynamic target. Staccato and fermata have no
unambiguous release target and disable release scoring. Their notated duration
remains visible. Ties have one attack target from their first note and one
release target at the end of the final continuation.

## Offline toolchain

Website builds need none of these engraving tools. To regenerate scores:

1. `python tools/setup-engraving.py` (public downloads into ignored `output/`).
2. `python tools/audit-sources.py`.
3. `python tools/engrave-scores.py`.
4. `python tools/map-engraving.py`.
5. `npx tsx tools/package-selected-scores.ts`.

The last step creates review candidates in `output/releases/scores`, and PNGs
decoded from the final PSC2 binary in `output/review`. It does not silently
replace the public catalog. All notes, rests and symbols are rendered at the
target page aspect ratio; measures may not cross pages. The two notations can
have different page layouts. Repeat routes refer back to their original pages.

Pinned Windows toolchain: LilyPond 2.24.4 and jianpu-ly 1.891. The setup script
checks SHA-256 before extraction. jianpu-ly is Apache-2.0; LilyPond is GPL-3.0-or-later.
Neither runtime is redistributed in this repository.

The selected-edition adapter records these engraving corrections explicitly:

- Bare `|` inside `A{}` means a new alternative to jianpu-ly; it is not used as
  a bar check. Each alternative is emitted exactly once in the printed score.
- Invisible chord-to-duration-dash ties in jianpu-ly 1.891 use mismatching
  placeholder pitches. Only these invisible ties are removed; real note-to-note
  ties remain. Dashes continue to represent the original duration.
- The converter's staccato triangle is drawn as a path, avoiding a missing
  SVG font glyph. It is not an extra musical target.
- Final bars retain the original final repeat (No.5) or double bar (No.6).
- Jianpu fingerings appear in parentheses; chord fingerings are listed in
  source chord-note order. Upper and lower parts occupy separate aligned lines.

Sources: [Mutopia No.5](https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=214),
[No.6](https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=215),
[No.2](https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=203),
[LilyPond](https://lilypond.org/),
[jianpu-ly](https://ssb22.user.srcf.net/mwrhome/jianpu-ly.html).
