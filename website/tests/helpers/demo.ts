import { expect } from "vitest";
import { parseScore, type Score } from "../../src/lib/pseq";
import { CMD } from "../../src/lib/protocol";
import { jsonBytes } from "../../src/lib/wire";
import { DemoLink, dataPayload, listEntries } from "../../src/lib/device";
import { encodeScore } from "../../tools/encode-score";
import { engineeringSource } from "../fixtures/engineering";

export function demoScore(suffix = "01") {
  const source = engineeringSource();
  source.id = "12345678-1234-5678-9abc-def0123456" + suffix;
  source.pages = [];
  source.anchors = [];
  source.capabilities = 1;
  return parseScore(encodeScore(source));
}
export const beginFields = (s: Score) => ({
  id: s.id, title: s.meta.title, total_bytes: s.bytes.length,
  file_crc: s.crc, package_major: 2, block_bytes: 512,
  total_blocks: Math.ceil(s.bytes.length / 512), capabilities: s.capabilities,
});
export const commitFields = (s: Score) => ({
  id: s.id, total_bytes: s.bytes.length, file_crc: s.crc,
});
export async function stageScore(link: DemoLink, score: Score) {
  await link.request(CMD.BEGIN, jsonBytes(beginFields(score)));
  for (let block = 0; block < Math.ceil(score.bytes.length / 512); block++)
    await link.request(CMD.DATA, dataPayload(score, block));
}
export async function deviceSnapshot(link: DemoLink) {
  return {
    status: await link.request(CMD.STATUS),
    entries: await listEntries(link),
    // The demo's public storage is also the explicit fault-injection seam.
    bytes: [...link.storage.records].map(([id, r]) => [id, r.bytes.slice()]),
  };
}
export async function unchangedFailure(link: DemoLink, action: () => Promise<unknown>, code: number) {
  const before = await deviceSnapshot(link);
  let notifications = 0;
  const listener = () => { notifications++; };
  link.storage.listeners.add(listener);
  try {
    await expect(action()).rejects.toMatchObject({ code });
    expect(await deviceSnapshot(link)).toEqual(before);
    expect(notifications).toBe(0);
  } finally {
    link.storage.listeners.delete(listener);
  }
}
