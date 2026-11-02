import { describe, it, expect } from "vitest";
import { encodeScore } from "../tools/encode-score";
import { parseScore, computeSafeStarts, tickToMs } from "../src/lib/psc2";
import { crc32 } from "../src/lib/pseq";
import { engineeringSource, expectedSafe } from "./fixtures/engineering";

function mutate(
  type: number,
  edit: (
    v: DataView,
    start: number,
    bytes: Uint8Array,
    directory: number,
  ) => void,
) {
  const bytes = encodeScore(engineeringSource()),
    v = new DataView(bytes.buffer);
  let o = 64;
  while (v.getUint32(o, true) !== type) o += 32;
  const start = v.getUint32(o + 8, true);
  edit(v, start, bytes, o);
  v.setUint32(
    o + 24,
    crc32(bytes.subarray(start, start + v.getUint32(o + 12, true))),
    true,
  );
  return bytes;
}
describe("PSC2 semantic and independent field checks", () => {
  it("encodes all eight sections and exact header, note, pixel and route values", () => {
    const bytes = encodeScore(engineeringSource()),
      v = new DataView(bytes.buffer),
      score = parseScore(bytes);
    expect([...bytes.slice(0, 8)]).toEqual([80, 83, 67, 50, 2, 0, 0, 0]);
    expect(v.getUint16(52, true)).toBe(960);
    expect(v.getUint16(54, true)).toBe(120);
    expect(v.getUint16(36, true)).toBe(8);
    expect(score.notes).toHaveLength(14);
    const noteOffset = v.getUint32(104, true);
    expect([...bytes.slice(noteOffset, noteOffset + 16)]).toEqual([
      0, 0, 0, 0, 224, 16, 0, 0, 48, 0, 1, 3, 0, 0, 0, 0,
    ]);
    expect(score.safeStarts).toEqual(expectedSafe);
    expect(
      score.anchors.filter((a) => a.notation === 1).map((a) => a.pageId),
    ).toEqual([0, 1, 0]);
    expect(score.pages[0]!.pixels[2401]).toBe(0x81);
    expect(score.notationPractice).toEqual([1, 2]);
    expect(bytes.length % 512).not.toBe(0);
    expect(tickToMs(960, 120)).toBe(500);
  });
  it("includes every safe candidate using both parts and unscored pedal", () => {
    const s = engineeringSource();
    expect(
      computeSafeStarts(s.notes, s.measures, s.controls, s.durationTicks),
    ).toEqual(expectedSafe);
    s.controls[3]!.tick = 7200;
    expect(
      computeSafeStarts(s.notes, s.measures, s.controls, s.durationTicks),
    ).not.toContain(7680);
  });
  it("accepts a notation without anchors as read-only, rejects partial mappings", () => {
    const s = engineeringSource();
    s.anchors = s.anchors.filter((a) => a.notation === 1);
    expect(parseScore(encodeScore(s)).notationPractice).toEqual([1]);
    s.anchors.pop();
    expect(() => encodeScore(s)).toThrow("部分覆盖");
  });
  it.each([
    [1, 1, "an overfull middle measure"],
    [1, 8, "an incomplete middle measure"],
    [0, 1, "an overfull first measure"],
    [2, 1, "an overfull final measure"],
  ] as const)(
    "rejects invalid meter length at measure %s, numerator %s: %s",
    (index, numerator) => {
      const bytes = mutate(4, (_v, start, b) => {
        b[start + index * 16 + 12] = numerator;
      });
      expect(() => parseScore(bytes)).toThrow("小节时长与拍号不一致");
    },
  );
  it("allows incomplete edge measures and complete measures in a different meter", () => {
    const bytes = mutate(4, (_v, start, b) => {
      // The first/final 3840-tick measures are incomplete 8/4 bars.
      b[start + 12] = 8;
      b[start + 32 + 12] = 8;
      // The middle 3840-tick measure remains complete in 8/8.
      b[start + 16 + 12] = 8;
      b[start + 16 + 13] = 3;
    });
    expect(
      parseScore(bytes).measures.map((m) => [m.numerator, m.denominatorPow]),
    ).toEqual([[8, 2], [8, 3], [8, 2]]);
  });
  it("allows one incomplete measure when it is both the first and final measure", () => {
    const source = engineeringSource();
    source.measures = [{
      index: 0,
      startTick: 0,
      endTick: source.durationTicks,
      numerator: 16,
      denominatorPow: 2,
    }];
    source.anchors = source.anchors.filter((a) => a.measureIndex === 0);
    // Removing the old measure boundaries removes no safe candidate here.
    expect(parseScore(encodeScore(source)).measures).toEqual(source.measures);
  });
  it.each([
    [
      2,
      "flags",
      (v: DataView, o: number, b: Uint8Array) => {
        b[o + 11] = 2;
      },
      "要求起音",
    ],
    [
      2,
      "dynamic",
      (v: DataView, o: number, b: Uint8Array) => {
        b[o + 11] = 7;
      },
      "缺少参考",
    ],
    [
      2,
      "same pitch duration",
      (v: DataView, o: number) => {
        v.setUint32(o + 20, 1200, true);
      },
      "同音重叠",
    ],
    [
      3,
      "pedal pair",
      (v: DataView, o: number, b: Uint8Array) => {
        b[o + 23] = 0;
      },
      "配对",
    ],
    [
      4,
      "measure gap",
      (v: DataView, o: number) => {
        v.setUint32(o + 16, 3841, true);
      },
      "小节",
    ],
    [
      5,
      "page profile",
      (v: DataView, o: number) => {
        v.setUint16(o + 8, 959, true);
      },
      "profile 1",
    ],
    [
      7,
      "page reference",
      (v: DataView, o: number) => {
        v.setUint32(o + 4, 99, true);
      },
      "引用",
    ],
    [
      7,
      "empty rectangle",
      (v: DataView, o: number) => {
        v.setUint16(o + 16, 0, true);
      },
      "矩形",
    ],
    [
      8,
      "unsafe point",
      (v: DataView, o: number) => {
        v.setUint32(o + 4, 3840, true);
      },
      "SAFE_START",
    ],
  ] as const)(
    "rejects %s %s even with repaired CRC",
    (type, _name, edit, message) => {
      expect(() => parseScore(mutate(type, edit))).toThrow(message);
    },
  );
  it("rejects missing safe candidates and overlapping incompatible source notes", () => {
    const s = engineeringSource();
    s.safeStarts.splice(2, 1);
    expect(() => encodeScore(s)).toThrow("缺失安全点");
    const other = engineeringSource();
    other.notes[1]!.pitch = 48;
    expect(() => encodeScore(other)).toThrow("同音重叠");
  });
  it("rejects CRC, header version and directory duplicates", () => {
    const b = encodeScore(engineeringSource());
    b[400] ^= 1;
    expect(() => parseScore(b)).toThrow("CRC");
    b[3] = 49;
    expect(() => parseScore(b)).toThrow("PSC2");
    expect(() =>
      parseScore(mutate(3, (v, _o, _b, dir) => v.setUint32(dir, 2, true))),
    ).toThrow("重复");
  });
  it("counts optional sections when enforcing the single nonzero profile rule", () => {
    expect(() =>
      parseScore(
        mutate(3, (v, _o, _b, dir) => {
          v.setUint32(dir, 99, true);
          v.setUint16(dir + 4, 2, true);
          v.setUint16(dir + 6, 0, true);
        }),
      ),
    ).toThrow("至多一种");
  });
});
