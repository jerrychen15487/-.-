import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { parseScore, uuidBytes } from "../src/lib/pseq";
import { CMD, ERR, isId } from "../src/lib/protocol";
import { jsonBytes } from "../src/lib/wire";
import { DemoLink, DemoStorage, dataPayload, deleteEntry, listEntries, transferScore,
  validateStatus, validateEntry, validateProgress, UnknownCommit, UnknownDelete, type Entry } from "../src/lib/device";
import { beginFields, demoScore, unchangedFailure } from "./helpers/demo";
import { encodeScore } from "../tools/encode-score";
import { engineeringSource } from "./fixtures/engineering";

const NIL = "00000000-0000-0000-0000-000000000000";

describe("nonzero song identity", () => {
  it("preserves canonical JSON IDs and case-insensitive byte encoding without adding UUID version restrictions", () => {
    const id = "00112233-4455-6677-8899-aabbccddeeff";
    expect(isId(id)).toBe(true);
    expect(isId(id.toUpperCase())).toBe(false);
    expect(isId("00000000-0000-0000-0000-000000000001")).toBe(true);
    for (const bad of [null, 1, "", "xyz", id.replaceAll("-", "")]) expect(isId(bad)).toBe(false);
    const expected = [0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187, 204, 221, 238, 255];
    expect([...uuidBytes(id)]).toEqual(expected);
    expect([...uuidBytes(id.toUpperCase())]).toEqual(expected);
    expect(() => encodeScore({ ...engineeringSource(), id: NIL })).toThrow("ID");
  });
  it("keeps null STATUS valid and rejects nil STATUS and directory identities", async () => {
    const link = new DemoLink(new DemoStorage(), {}, 0), score = demoScore();
    const status = await link.request<Record<string, unknown>>(CMD.STATUS);
    expect(validateStatus(status).active_id).toBeNull();
    expect(() => validateStatus({ ...status, active_id: NIL })).toThrow("活动传输");
    await link.request(CMD.BEGIN, jsonBytes(beginFields(score)));
    const entry = (await listEntries(link))[0]!;
    expect(validateEntry(entry).id).toBe(score.id);
    expect(() => validateEntry({ ...entry, id: NIL })).toThrow("目录条目");
    link.faults.after = (type, response) => {
      if (type === CMD.LIST) (response as { items: Entry[] }).items[0]!.id = NIL;
    };
    await expect(listEntries(link)).rejects.toThrow("目录条目");
  });
  it.each([CMD.BEGIN, CMD.DATA, CMD.PAUSE])("does not accept nil progress ACK for command %i", (type) => {
    const score = demoScore();
    const progress = { request_type: type, id: NIL, next_block: 0,
      total_blocks: Math.ceil(score.bytes.length / 512), saved_bytes: 0 };
    expect(() => validateProgress(progress, type, score)).toThrow("确认进度");
    expect(validateProgress({ ...progress, id: score.id }, type, score).saved_bytes).toBe(0);
  });
  it.each([true, false])("requires independent directory evidence after nil COMMIT ACK (directory available: %s)", async (available) => {
    const score = demoScore(), calls: number[] = [];
    const link = new DemoLink(new DemoStorage(), {
      before: (type) => {
        calls.push(type);
        if (type === CMD.LIST && !available) throw Error("directory unavailable");
      },
      after: (type, response) => { if (type === CMD.COMMIT) (response as { id: string }).id = NIL; },
    }, 0);
    const stages: string[] = [];
    const result = transferScore(link, score, link.storage.caps, new AbortController().signal, (_n, stage) => stages.push(stage));
    if (available) await expect(result).resolves.toBeUndefined();
    else await expect(result).rejects.toBeInstanceOf(UnknownCommit);
    expect(calls).toContain(CMD.LIST);
    expect(stages.includes("已保存")).toBe(available);
  });
  it.each([true, false])("requires independent directory evidence after nil DELETE ACK (directory available: %s)", async (available) => {
    const score = demoScore(), link = new DemoLink(new DemoStorage(), {}, 0);
    await link.request(CMD.BEGIN, jsonBytes(beginFields(score)));
    const entry = (await listEntries(link))[0]!, calls: number[] = [];
    link.faults.before = (type) => {
      calls.push(type);
      if (type === CMD.LIST && !available) throw Error("directory unavailable");
    };
    link.faults.after = (type, response) => { if (type === CMD.DELETE) (response as { id: string }).id = NIL; };
    if (available) await expect(deleteEntry(link, entry)).resolves.toBeUndefined();
    else await expect(deleteEntry(link, entry)).rejects.toBeInstanceOf(UnknownDelete);
    expect(calls.filter((t) => t === CMD.DELETE)).toHaveLength(1);
    expect(calls).toContain(CMD.LIST);
  });
  it.each([CMD.BEGIN, CMD.DATA, CMD.COMMIT, CMD.PAUSE, CMD.DELETE])("rejects nil command %i without changing an active download", async (type) => {
    const score = demoScore(), link = new DemoLink(new DemoStorage(), {}, 0);
    await link.request(CMD.BEGIN, jsonBytes(beginFields(score)));
    await link.request(CMD.DATA, dataPayload(score, 0));
    const payload = type === CMD.DATA ? dataPayload(score, 1) : jsonBytes({ ...beginFields(score), id: NIL });
    if (type === CMD.DATA) payload.fill(0, 0, 16);
    await unchangedFailure(link, () => link.request(type, payload), ERR.BAD_REQUEST);
  });
  it("rejects an invalid delete target before contacting the device", async () => {
    const score = demoScore(), link = new DemoLink(new DemoStorage(), {}, 0);
    await link.request(CMD.BEGIN, jsonBytes(beginFields(score)));
    const entry = (await listEntries(link))[0]!;
    const calls: number[] = [];
    link.faults.before = (type) => { calls.push(type); };
    await expect(deleteEntry(link, { ...entry, id: NIL })).rejects.toThrow("曲目身份");
    expect(calls).toEqual([]);
  });
  it("rejects a nil file header without relying on section CRC failure", () => {
    const original = new Uint8Array(readFileSync("tests/fixtures/packages/engineering.pseq"));
    const invalid = original.slice();
    invalid.fill(0, 12, 28);
    expect(invalid.subarray(28)).toEqual(original.subarray(28));
    expect(() => parseScore(invalid)).toThrow("非法曲目身份");
    expect(isId(NIL)).toBe(false);
    expect(() => uuidBytes(NIL)).toThrow();
  });
});
