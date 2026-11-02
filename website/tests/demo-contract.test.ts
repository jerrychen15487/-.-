import { describe, expect, it } from "vitest";
import { CMD, ERR } from "../src/lib/protocol";
import { jsonBytes } from "../src/lib/wire";
import { DemoLink, DemoStorage, dataPayload, listEntries } from "../src/lib/device";
import { beginFields, commitFields, demoScore, stageScore, unchangedFailure, deviceSnapshot } from "./helpers/demo";

describe("demo contract shared with the persistent receiver", () => {
  it("commits the active song normally but requires BEGIN again after PAUSE", async () => {
    const link = new DemoLink(new DemoStorage(), {}, 0), a = demoScore();
    await stageScore(link, a);
    await link.request(CMD.PAUSE, jsonBytes({ id: a.id }));
    await unchangedFailure(link, () => link.request(CMD.COMMIT, jsonBytes(commitFields(a))), ERR.BUSY);
    await link.request(CMD.BEGIN, jsonBytes(beginFields(a)));
    const before = await deviceSnapshot(link);
    await link.request(CMD.COMMIT, jsonBytes(commitFields(a)));
    expect(await link.request(CMD.STATUS)).toMatchObject({ active_id: null, phase: 0 });
    expect((await listEntries(link))[0]!.entry_state).toBe(2);
    expect((await deviceSnapshot(link)).bytes).toEqual(before.bytes);
  });
  it("keeps B active when already complete A is committed idempotently", async () => {
    const link = new DemoLink(new DemoStorage(), {}, 0), a = demoScore(), b = demoScore("02");
    await stageScore(link, a);
    const committed = await link.request(CMD.COMMIT, jsonBytes(commitFields(a)));
    await link.request(CMD.BEGIN, jsonBytes(beginFields(b)));
    await link.request(CMD.DATA, dataPayload(b, 0));
    const before = await deviceSnapshot(link);
    let notifications = 0;
    link.onChanged = () => { notifications++; };
    expect(await link.request(CMD.COMMIT, jsonBytes(commitFields(a)))).toEqual(committed);
    expect(await deviceSnapshot(link)).toEqual(before);
    expect(notifications).toBe(0);
    for (const field of ["total_bytes", "file_crc"] as const) {
      const payload = commitFields(a);
      payload[field]++;
      await unchangedFailure(link, () => link.request(CMD.COMMIT, jsonBytes(payload)), ERR.CONTENT_MISMATCH);
    }
  });
  it.each([1, 2, 3])("rejects partial and complete COMMIT in mode %i without mutation", async (mode) => {
    const link = new DemoLink(new DemoStorage(), {}, 0), a = demoScore(), b = demoScore("02");
    await stageScore(link, a);
    await link.request(CMD.COMMIT, jsonBytes(commitFields(a)));
    await stageScore(link, b);
    link.storage.setMode(mode);
    for (const score of [a, b])
      await unchangedFailure(link, () => link.request(CMD.COMMIT, jsonBytes(commitFields(score))), ERR.BUSY);
  });
  it("reserves and resumes a partial with full complete slots, then commits after freeing a slot without DATA replay", async () => {
    const storage = new DemoStorage(), link = new DemoLink(storage, {}, 0), a = demoScore(), b = demoScore("02");
    storage.caps.max_complete_songs = 1;
    storage.capacity = a.bytes.length + b.bytes.length;
    await stageScore(link, b);
    await link.request(CMD.COMMIT, jsonBytes(commitFields(b)));
    await link.request(CMD.BEGIN, jsonBytes(beginFields(a)));
    await link.request(CMD.DATA, dataPayload(a, 0));
    await link.request(CMD.PAUSE, jsonBytes({ id: a.id }));
    expect(await link.request(CMD.BEGIN, jsonBytes(beginFields(a)))).toMatchObject({ next_block: 1, saved_bytes: 512 });
    for (let i = 1; i < Math.ceil(a.bytes.length / 512); i++) await link.request(CMD.DATA, dataPayload(a, i));
    await unchangedFailure(link, () => link.request(CMD.COMMIT, jsonBytes(commitFields(a))), ERR.NO_SPACE);
    await link.request(CMD.DELETE, jsonBytes({ id: b.id }));
    await expect(link.request(CMD.COMMIT, jsonBytes(commitFields(a)))).resolves.toMatchObject({ entry_state: 2 });
    expect((await listEntries(link)).map((e) => e.id)).toEqual([a.id]);
  });
  it.each([false, true])("deletes nonactive B (complete: %s) without changing A, and clears only an active DELETE", async (complete) => {
    const link = new DemoLink(new DemoStorage(), {}, 0), a = demoScore(), b = demoScore("02");
    await stageScore(link, b);
    await link.request(complete ? CMD.COMMIT : CMD.PAUSE, jsonBytes(commitFields(b)));
    await link.request(CMD.BEGIN, jsonBytes(beginFields(a)));
    await link.request(CMD.DATA, dataPayload(a, 0));
    const before = await deviceSnapshot(link);
    await link.request(CMD.DELETE, jsonBytes({ id: b.id }));
    expect(await link.request(CMD.STATUS)).toMatchObject({ active_id: a.id, phase: 1, next_block: 1 });
    expect(await listEntries(link)).toEqual(before.entries.filter((e) => e.id === a.id));
    expect((await deviceSnapshot(link)).bytes).toEqual(before.bytes.filter(([id]) => id === a.id));
    const deleted = await deviceSnapshot(link);
    let notifications = 0;
    link.onChanged = () => { notifications++; };
    expect(await link.request(CMD.DELETE, jsonBytes({ id: b.id }))).toMatchObject({ deleted: false });
    expect(await deviceSnapshot(link)).toEqual(deleted);
    expect(notifications).toBe(0);
    await link.request(CMD.DELETE, jsonBytes({ id: a.id }));
    expect(await link.request(CMD.STATUS)).toMatchObject({ active_id: null, phase: 0, next_block: 0, total_blocks: 0 });
    expect(await listEntries(link)).toEqual([]);
  });
  it("rejects COMMIT of paused A while B is active, then resumes and commits A without retransmission", async () => {
    const link = new DemoLink(new DemoStorage(), {}, 0), a = demoScore(), b = demoScore("02");
    await stageScore(link, a);
    await link.request(CMD.PAUSE, jsonBytes({ id: a.id }));
    await link.request(CMD.BEGIN, jsonBytes(beginFields(b)));
    await unchangedFailure(link, () => link.request(CMD.COMMIT, jsonBytes(commitFields(a))), ERR.BUSY);
    await link.request(CMD.PAUSE, jsonBytes({ id: b.id }));
    expect(await link.request(CMD.BEGIN, jsonBytes(beginFields(a)))).toMatchObject({
      next_block: Math.ceil(a.bytes.length / 512), saved_bytes: a.bytes.length,
    });
    await expect(link.request(CMD.COMMIT, jsonBytes(commitFields(a)))).resolves.toMatchObject({ id: a.id, entry_state: 2 });
    expect(await link.request(CMD.STATUS)).toMatchObject({ active_id: null, phase: 0 });
    expect((await listEntries(link)).find((e) => e.id === a.id)?.entry_state).toBe(2);
  });
});
