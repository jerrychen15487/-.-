import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { parseScore, uuidBytes } from "../src/lib/pseq";
import { ScoreSourceCache, fingerprint } from "../src/lib/source-cache";

const bytes = new Uint8Array(readFileSync("tests/fixtures/packages/engineering.pseq"));
function source(index: number) {
  const copy = bytes.slice();
  copy.set(uuidBytes(`12345678-1234-5678-9abc-def01234567${index}`), 12);
  return parseScore(copy);
}

describe("bounded resume sources", () => {
  it("keeps recently used sources while evicting the least recently used file", () => {
    const cache = new ScoreSourceCache(bytes.length * 2);
    const a = source(1), b = source(2), c = source(3);
    cache.remember(a);
    cache.remember(b);
    expect(cache.get(fingerprint(a))).toBe(a);
    cache.remember(c);
    expect(cache.get(fingerprint(b))).toBeUndefined();
    expect(cache.get(fingerprint(a))).toBe(a);
    expect(cache.get(fingerprint(c))).toBe(c);
  });

  it("matches UUID, length and CRC and releases an explicitly deleted source", () => {
    const cache = new ScoreSourceCache();
    const a = source(1);
    cache.remember(a);
    expect(cache.get({ ...fingerprint(a), file_crc: a.crc ^ 1 })).toBeUndefined();
    expect(cache.get({ ...fingerprint(a), total_bytes: a.bytes.length + 1 })).toBeUndefined();
    cache.delete(fingerprint(a));
    expect(cache.get(fingerprint(a))).toBeUndefined();
  });

  it("does not evict an existing file when the new source exceeds its budget", () => {
    const cache = new ScoreSourceCache(bytes.length);
    const a = source(1), b = source(2);
    cache.remember(a);
    cache.remember({ ...b, bytes: new Uint8Array(bytes.length + 1) });
    expect(cache.get(fingerprint(a))).toBe(a);
  });
});
