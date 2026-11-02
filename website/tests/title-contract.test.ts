import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { parseScore, crc32 } from "../src/lib/pseq";
import { CMD, ERR, validTitle } from "../src/lib/protocol";
import { jsonBytes } from "../src/lib/wire";
import { DemoLink, DemoStorage, listEntries } from "../src/lib/device";
import { beginFields, demoScore, unchangedFailure } from "./helpers/demo";

// Mutate a final package, not the encoder's semantic input. Move only META to
// aligned EOF so bitmap absolute offsets and every other section remain intact.
function withTitle(title: string) {
  const original = new Uint8Array(readFileSync("tests/fixtures/packages/engineering.pseq"));
  const header = new DataView(original.buffer);
  let directory = 64;
  while (header.getUint32(directory, true) !== 1) directory += 32;
  const start = header.getUint32(directory + 8, true), size = header.getUint32(directory + 12, true);
  const meta = JSON.parse(new TextDecoder().decode(original.subarray(start, start + size)));
  const data = new TextEncoder().encode(JSON.stringify({ ...meta, title }));
  const bytes = new Uint8Array(Math.ceil((original.length + data.length) / 4) * 4);
  bytes.set(original);
  bytes.fill(0, start, start + size);
  bytes.set(data, original.length);
  const view = new DataView(bytes.buffer);
  view.setUint32(8, bytes.length, true);
  view.setUint32(directory + 8, original.length, true);
  view.setUint32(directory + 12, data.length, true);
  view.setUint32(directory + 24, crc32(data), true);
  return bytes;
}

describe("shared Unicode title boundaries at META and BEGIN", () => {
  it.each([
    ["one scalar", "A"], ["128 ASCII", "A".repeat(128)],
    ["384 bytes / 128 scalars", "琴".repeat(128)],
    ["384 bytes / 96 supplementary scalars", "🎹".repeat(96)],
    ["space preserved", " "], ["decomposed text preserved", "e\u0301"],
  ])("accepts %s", async (_name, title) => {
    expect(validTitle(title)).toBe(true);
    expect(parseScore(withTitle(title)).meta.title).toBe(title);
    const link = new DemoLink(new DemoStorage(), {}, 0);
    await link.request(CMD.BEGIN, jsonBytes({ ...beginFields(demoScore()), title }));
    expect((await listEntries(link))[0]!.title).toBe(title);
  });
  it.each([
    ["empty", ""], ["129 scalars", "A".repeat(129)],
    ["388 bytes / 97 scalars", "🎹".repeat(97)],
    ["lone high surrogate", "\ud800"], ["lone low surrogate", "\udfff"],
    ...Array.from({ length: 32 }, (_, code) => [`C0 ${code}`, `A${String.fromCharCode(code)}B`]),
  ])("rejects %s without reserving storage", async (_name, title) => {
    expect(validTitle(title)).toBe(false);
    expect(() => parseScore(withTitle(title))).toThrow("标题");
    const link = new DemoLink(new DemoStorage(), {}, 0);
    await unchangedFailure(link, () => link.request(CMD.BEGIN, jsonBytes({ ...beginFields(demoScore()), title })), ERR.BAD_REQUEST);
  });
});
