import { describe, it, expect } from "vitest";
import { ScoreTimeline } from "../src/lib/timeline";
import { parseScore } from "../src/lib/pseq";
import { readFileSync } from "node:fs";
describe("shared tick timeline", () => {
  const score = parseScore(
      new Uint8Array(readFileSync("tests/fixtures/packages/engineering.pseq")),
    ),
    t = new ScoreTimeline(score);
  it("seeks across long holds and finds both parts without scanning from song start", () => {
    expect(t.visibleNotes(4000, 400).map((n) => n.pitch)).toEqual([48]);
    expect(t.visibleNotes(5000, 300).map((n) => n.pitch)).toEqual([60]);
  });
  it("uses binary anchors for backwards page references and simultaneous notation views", () => {
    expect(t.anchorAt(4000, 1)?.pageId).toBe(1);
    expect(t.anchorAt(8000, 1)?.pageId).toBe(0);
    expect(t.anchorAt(8000, 2)?.pageId).toBe(2);
    expect(t.measureAt(8000)?.index).toBe(2);
  });
  it("recomputes pedal state on forward and backward seeks including threshold values", () => {
    expect(t.pedalAt(960)).toBe(true);
    expect(t.pedalAt(4800)).toBe(false);
    expect(t.pedalAt(7680)).toBe(true);
    expect(t.pedalAt(8640)).toBe(false);
    expect(t.pedalAt(0)).toBe(false);
  });
});
