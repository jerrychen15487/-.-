import { readFileSync } from "node:fs";
import { describe, it, expect } from "vitest";
import vectors from "./fixtures/scoring-vectors.json";
import packages from "./fixtures/handoff-packages.json";
import {
  timing,
  hold,
  dynamic,
  pedal,
  total,
  match,
  rollback,
} from "../tools/scoring-reference";
import { parseScore } from "../src/lib/psc2";

describe("offline FPGA handoff with fixed independent expectations", () => {
  it("checks onset, first release, pedal, velocity boundaries and normalized weights", () => {
    for (const [ms, expected] of vectors.onset)
      expect(timing(ms!)).toBe(expected);
    for (const v of vectors.hold)
      expect(hold(...(v.input as Parameters<typeof hold>))).toBeCloseTo(
        v.expected,
      );
    for (const v of vectors.pedal)
      expect(pedal(...(v.input as Parameters<typeof pedal>))).toBeCloseTo(
        v.expected,
      );
    for (const v of vectors.dynamics) {
      for (const n of [v.lo, v.hi]) expect(dynamic(v.level, n)).toBe(100);
      for (const n of [v.lo - 1, v.hi + 1]) expect(dynamic(v.level, n)).toBe(0);
      expect(dynamic(v.level, v.lo, false)).toBe(0);
    }
    expect(dynamic(0, 127)).toBeNull();
    for (const [value, down] of vectors.pedal_states)
      expect(Number(value) >= 64).toBe(down);
    for (const v of vectors.weights) expect(total(v.parts)).toBe(v.expected);
  });
  it("consumes each target once, exempts unselected and unscored notes, counts common notes", () => {
    const v = vectors.matching;
    expect(match(v.targets, v.events, v.part)).toEqual(v.expected);
  });
  it("rolls back target and combo history at the all-part safe boundary", () => {
    const v = vectors.rollback;
    expect(rollback(v.safe, v.pause, v.results, v.history)).toEqual(v.expected);
    for (const [pause, start] of v.additional_pause_start)
      expect(rollback(v.safe, pause!, [], []).start).toBe(start);
  });
  it.each(vectors.rollback_boundaries)(
    "rolls back $name by target ownership",
    (v) => {
      expect(rollback(v.safe, v.pause, v.results, v.history)).toEqual(v.expected);
    },
  );
  it("recomputes current and maximum combo on a second earlier rollback", () => {
    const v = vectors.rollback;
    const first = rollback(v.safe, v.pause, v.results, v.history);
    expect(
      rollback(
        v.safe,
        5000,
        v.results.filter((r) => first.keep.includes(r.id)),
        first.history,
      ),
    ).toEqual({
      start: 4800,
      keep: [0],
      combo: 1,
      maxCombo: 1,
      history: [{ tick: 0, correct: true, targetId: 0 }],
    });
  });
  it("matches Python struct/zlib final-package pixels, CRCs, anchors and safe tables", () => {
    for (const item of packages) {
      const s = parseScore(new Uint8Array(readFileSync(item.file)));
      expect(s.crc.toString(16).toUpperCase().padStart(8, "0")).toBe(
        item.crc32,
      );
      expect(s.safeStarts).toEqual(item.safe_starts);
      expect(
        s.anchors.map((a) => ({
          tick: a.startTick,
          page_id: a.pageId,
          measure: a.measureIndex,
          x: a.x,
          y: a.y,
          width: a.width,
          height: a.height,
          notation: a.notation,
        })),
      ).toEqual(item.anchors);
      for (const p of item.pages) {
        const page = s.pages.find((x) => x.id === p.page_id)!;
        for (const [x, y] of p.black_xy)
          expect(
            page.pixels[y! * 120 + (x! >> 3)]! & (128 >> (x! & 7)),
          ).not.toBe(0);
      }
    }
  });
});
