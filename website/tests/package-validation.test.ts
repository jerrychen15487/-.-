import { readFileSync } from "node:fs";
import { describe, it, expect } from "vitest";
import { parseScore, crc32 } from "../src/lib/pseq";
const sample = () =>
  new Uint8Array(readFileSync("tests/fixtures/packages/engineering.pseq"));
describe("independent persisted engineering packages", () => {
  it("has a fixed manual safe table and exact three-tuplet timings", () => {
    const s = parseScore(sample());
    expect(s.safeStarts).toEqual([
      0, 4800, 5760, 7680, 8640, 9600, 9920, 10240,
    ]);
    expect(
      s.notes.slice(-3).map((n) => [n.startTick, n.durationTicks]),
    ).toEqual([
      [9600, 320],
      [9920, 320],
      [10240, 320],
    ]);
    expect(s.pages[0]!.pixels[2401]).toBe(129);
    expect(s.pages[0]!.pixels[2400]).toBe(0);
  });
  it.each(["bad-crc", "bad-anchor", "unsafe-start", "bad-score-flags"])(
    "rejects fixed invalid package %s",
    (name) => {
      expect(() =>
        parseScore(
          new Uint8Array(readFileSync(`tests/fixtures/packages/${name}.pseq`)),
        ),
      ).toThrow();
    },
  );
  it("rejects a misaligned section and nonzero padding", () => {
    const b = sample(),
      v = new DataView(b.buffer);
    v.setUint32(72, v.getUint32(72, true) + 1, true);
    expect(() => parseScore(b)).toThrow("未对齐");
    const c = sample(),
      w = new DataView(c.buffer),
      end = w.getUint32(72, true) + w.getUint32(76, true);
    expect(end % 4).not.toBe(0);
    c[end] = 1;
    expect(() => parseScore(c)).toThrow("填充");
  });
  it("rejects bad note sorting even when the section CRC is repaired", () => {
    const b = sample(),
      v = new DataView(b.buffer),
      start = v.getUint32(104, true),
      length = v.getUint32(108, true);
    b[start + 8] = 70;
    v.setUint32(120, crc32(b.subarray(start, start + length)), true);
    expect(() => parseScore(b)).toThrow("排序");
  });
});
