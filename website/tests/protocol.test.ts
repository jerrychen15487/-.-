import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { parseScore, crc32 } from "../src/lib/pseq";
import { CMD, FrameDecoder, encodeFrame, jsonBytes } from "../src/lib/wire";
import { DemoStorage, validateCaps, validateStatus } from "../src/lib/device";
const catalog = JSON.parse(readFileSync("public/scores/catalog.json", "utf8"));
describe("published PSC2 and v2 wire", () => {
  it("contains exactly the three complete selected works and matching final binary data", () => {
    expect(catalog).toHaveLength(3);
    for (const item of catalog) {
      const bytes = new Uint8Array(readFileSync("public/" + item.file)),
        s = parseScore(bytes);
      expect(s.id).toBe(item.id);
      expect(s.crc).toBe(item.crc);
      expect(s.bytes.length).toBe(item.bytes);
      expect(s.notes.length).toBe(item.notes);
      expect(s.notationPractice).toEqual([1, 2]);
      expect(s.pages.every((p) => p.pixels.length === 57600)).toBe(true);
    }
  });
  it("matches the independent CRC standard and published empty CAPS frame", () => {
    expect(crc32(new TextEncoder().encode("123456789"))).toBe(0xcbf43926);
    const frame = encodeFrame({
      type: CMD.CAPS,
      session: 0x11223344,
      seq: 1,
      payload: new Uint8Array(),
    });
    expect([...frame.slice(0, 16)]).toEqual([
      165, 90, 2, 1, 68, 51, 34, 17, 1, 0, 0, 0, 0, 0, 0, 0,
    ]);
    expect(crc32(frame.slice(2, 16))).toBe(
      new DataView(frame.buffer).getUint32(16, true),
    );
  });
  it("decodes every split and resynchronizes after corrupt frames", () => {
    const frame = encodeFrame({
      type: CMD.DATA,
      session: 12,
      seq: 7,
      payload: Uint8Array.from([165, 90, 1, 2, 3]),
    });
    for (let cut = 0; cut <= frame.length; cut++) {
      const d = new FrameDecoder();
      expect([
        ...d.push(frame.slice(0, cut)),
        ...d.push(frame.slice(cut)),
      ]).toEqual([
        { type: CMD.DATA, session: 12, seq: 7, payload: frame.slice(16, -4) },
      ]);
    }
    const bad = frame.slice();
    bad[16] ^= 1;
    expect(
      new FrameDecoder().push(new Uint8Array([...bad, ...frame, ...frame])),
    ).toHaveLength(2);
  });
  it("rejects PSC1, truncation, reserved header fields and oversized JSON", () => {
    const bytes = new Uint8Array(readFileSync("public/" + catalog[0].file));
    for (const size of [0, 63, 64, bytes.length - 1])
      expect(() => parseScore(bytes.slice(0, size))).toThrow();
    const old = bytes.slice();
    old[3] = 49;
    expect(() => parseScore(old)).toThrow("PSC2");
    const reserved = bytes.slice();
    reserved[56] = 1;
    expect(() => parseScore(reserved)).toThrow("保留");
    expect(() => jsonBytes({ text: "x".repeat(1024) })).toThrow("1024");
  });
  it("keeps u64 capacity exact and rejects legacy string modes or numeric capacities", () => {
    const status = {
      request_type: CMD.STATUS,
      mode: 0,
      phase: 0,
      generation: 1,
      free_bytes: "18446744073709551615",
      active_id: null,
      next_block: 0,
      total_blocks: 0,
    };
    expect(validateStatus(status).free_bytes).toBe(18446744073709551615n);
    expect(() => validateStatus({ ...status, free_bytes: 100 })).toThrow();
    expect(() => validateStatus({ ...status, mode: "LIBRARY" })).toThrow();
    expect(() =>
      validateCaps({ ...new DemoStorage().caps, protocol: 1 }),
    ).toThrow();
  });
});
