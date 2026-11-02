import { describe, it, expect } from "vitest";
import { encodeScore } from "../tools/encode-score";
import { engineeringSource } from "./fixtures/engineering";
import { parseScore } from "../src/lib/pseq";
import { CMD, ERR } from "../src/lib/protocol";
import { jsonBytes, readJson } from "../src/lib/wire";
import {
  DemoLink,
  DemoStorage,
  DeviceError,
  TransportError,
  TransferPaused,
  TransferStopped,
  UnknownCommit,
  UnknownDelete,
  transferScore,
  deleteEntry,
  listEntries,
  dataPayload,
  type Progress,
} from "../src/lib/device";
const score = (suffix = "01") => {
  const s = engineeringSource();
  s.id = "12345678-1234-5678-9abc-def0123456" + suffix;
  s.pages = [];
  s.anchors = [];
  s.capabilities = 1;
  return parseScore(encodeScore(s));
};
const start = (s: ReturnType<typeof score>) =>
  jsonBytes({
    id: s.id,
    title: s.meta.title,
    total_bytes: s.bytes.length,
    file_crc: s.crc,
    package_major: 2,
    block_bytes: 512,
    total_blocks: Math.ceil(s.bytes.length / 512),
    capabilities: s.capabilities,
  });
const run = (
  l: DemoLink,
  s = score(),
  signal = new AbortController().signal,
  progress = (_n: number, _stage: string) => {},
) => transferScore(l, s, l.storage.caps, signal, progress);

describe("persistent-device business model (browser simulation)", () => {
  it("pauses A, completes B, then resumes A even with zero additional free space", async () => {
    const storage = new DemoStorage(),
      l = new DemoLink(storage, {}, 0),
      a = score(),
      b = score("02"),
      abort = new AbortController();
    storage.capacity = a.bytes.length + b.bytes.length;
    await expect(
      run(l, a, abort.signal, (n) => {
        if (n === 512) abort.abort("user");
      }),
    ).rejects.toBeInstanceOf(TransferPaused);
    expect(storage.records.get(a.id)!.entry.next_block).toBe(1);
    expect(storage.activeId).toBeNull();
    await run(l, b);
    expect(storage.freeBytes).toBe(0);
    const sent: number[] = [];
    const original = l.request.bind(l);
    l.request = async (type, payload) => {
      if (type === CMD.DATA)
        sent.push(
          new DataView(payload!.buffer, payload!.byteOffset).getUint32(
            16,
            true,
          ),
        );
      return original(type, payload) as never;
    };
    await run(l, a);
    expect(sent[0]).toBe(1);
    expect((await listEntries(l)).every((e) => e.entry_state === 2)).toBe(true);
  });
  it("uses saved next_block after DATA was stored but its ACK was lost", async () => {
    const storage = new DemoStorage();
    let lost = false;
    const l = new DemoLink(
        storage,
        {
          after: (type) => {
            if (type === CMD.DATA && !lost) {
              lost = true;
              throw new TransportError("ACK_TIMEOUT", "lost");
            }
          },
        },
        0,
      ),
      s = score();
    await expect(run(l, s)).rejects.toThrow("lost");
    expect(storage.records.get(s.id)!.entry.next_block).toBe(1);
    l.close();
    storage.restart();
    const next = new DemoLink(storage, {}, 0);
    await run(next, s);
    expect(storage.records.get(s.id)!.entry.entry_state).toBe(2);
  });
  it("does not advance confirmed progress on a mismatched DATA ACK", async () => {
    const l = new DemoLink(
        new DemoStorage(),
        {
          after: (type, r) => {
            if (type === CMD.DATA) (r as Progress).saved_bytes++;
          },
        },
        0,
      ),
      confirmed: number[] = [];
    await expect(
      run(l, score(), undefined, (n) => confirmed.push(n)),
    ).rejects.toThrow("确认进度");
    expect(confirmed).toEqual([0]);
  });
  it("stops after local mode change and never auto-resumes on returning to management", async () => {
    const l = new DemoLink(new DemoStorage(), {}, 0),
      a = score(),
      abort = new AbortController();
    l.onChanged = (e) => {
      if (e.mode !== 0) abort.abort("mode");
    };
    await expect(
      run(l, a, abort.signal, (n) => {
        if (n === 512) l.storage.setMode(3);
      }),
    ).rejects.toBeInstanceOf(TransferStopped);
    expect(l.storage.records.get(a.id)!.entry.next_block).toBe(1);
    l.storage.setMode(0);
    expect(l.storage.records.get(a.id)!.entry.next_block).toBe(1);
    await run(l, a);
    expect(l.storage.records.get(a.id)!.entry.entry_state).toBe(2);
  });
  it("confirms a lost PAUSE reply by checking inactive status and the matching partial", async () => {
    const l = new DemoLink(
        new DemoStorage(),
        {
          after: (type) => {
            if (type === CMD.PAUSE)
              throw new TransportError("ACK_TIMEOUT", "lost pause");
          },
        },
        0,
      ),
      a = score(),
      abort = new AbortController();
    await expect(
      run(l, a, abort.signal, (n) => {
        if (n === 512) abort.abort("user");
      }),
    ).rejects.toBeInstanceOf(TransferPaused);
  });
  it("reconciles unknown COMMIT from directory, and preserves a commit across a disconnected reply", async () => {
    const a = score(),
      storage = new DemoStorage();
    let link: DemoLink;
    link = new DemoLink(
      storage,
      {
        after: (type) => {
          if (type === CMD.COMMIT) {
            link.close();
            throw new TransportError("DISCONNECTED", "lost commit");
          }
        },
      },
      0,
    );
    await expect(run(link, a)).rejects.toBeInstanceOf(UnknownCommit);
    expect((await listEntries(new DemoLink(storage, {}, 0)))[0]).toMatchObject({
      id: a.id,
      file_crc: a.crc,
      entry_state: 2,
    });
    const l = new DemoLink(
      new DemoStorage(),
      {
        after: (type) => {
          if (type === CMD.COMMIT)
            throw new TransportError("ACK_TIMEOUT", "lost");
        },
      },
      0,
    );
    await expect(run(l, a)).resolves.toBeUndefined();
  });
  it("handles lost DELETE without replaying a delete on a newly started record", async () => {
    const storage = new DemoStorage(),
      normal = new DemoLink(storage, {}, 0),
      a = score();
    await run(normal, a);
    const entry = (await listEntries(normal))[0]!;
    let l: DemoLink,
      deletes = 0;
    l = new DemoLink(
      storage,
      {
        after: (type) => {
          if (type === CMD.DELETE) {
            deletes++;
            l.close();
            throw new TransportError("DISCONNECTED", "lost");
          }
        },
      },
      0,
    );
    await expect(deleteEntry(l, entry)).rejects.toBeInstanceOf(UnknownDelete);
    const next = new DemoLink(storage, {}, 0);
    await next.request(CMD.BEGIN, start(a));
    expect((await listEntries(next))[0]!.entry_state).toBe(1);
    expect(deletes).toBe(1);
  });
  it("accepts absent DELETE false, rejects implicit complete replacement and partial mismatch", async () => {
    const l = new DemoLink(new DemoStorage(), {}, 0),
      a = score();
    await run(l, a);
    const entry = (await listEntries(l))[0]!;
    await expect(run(l, a)).rejects.toMatchObject({ code: ERR.ALREADY_STORED });
    await deleteEntry(l, entry);
    await deleteEntry(l, entry);
    await l.request(CMD.BEGIN, start(a));
    const changed = readJson<Record<string, unknown>>(start(a));
    changed.file_crc = 0;
    await expect(
      l.request(CMD.BEGIN, jsonBytes(changed)),
    ).rejects.toMatchObject({ code: ERR.CONTENT_MISMATCH });
  });
  it("validates repeated tail bytes, storage failures and post-completion commit idempotency", async () => {
    const l = new DemoLink(new DemoStorage(), {}, 0),
      a = score();
    await l.request(CMD.BEGIN, start(a));
    for (let i = 0; i < Math.ceil(a.bytes.length / 512); i++)
      await l.request(CMD.DATA, dataPayload(a, i));
    const tail = dataPayload(a, Math.ceil(a.bytes.length / 512) - 1);
    expect(tail.length).toBeLessThan(532);
    await l.request(CMD.DATA, tail);
    const bad = tail.slice();
    bad[20] ^= 1;
    await expect(l.request(CMD.DATA, bad)).rejects.toMatchObject({
      code: ERR.CONTENT_MISMATCH,
    });
    const p = jsonBytes({
      id: a.id,
      total_bytes: a.bytes.length,
      file_crc: a.crc,
    });
    expect(await l.request(CMD.COMMIT, p)).toEqual(
      await l.request(CMD.COMMIT, p),
    );
    const failed = new DemoLink(
      new DemoStorage(),
      {
        before: (type) => {
          if (type === CMD.DATA) throw new DeviceError(ERR.STORAGE_ERROR);
        },
      },
      0,
    );
    await expect(run(failed, a)).rejects.toMatchObject({
      code: ERR.STORAGE_ERROR,
    });
    expect(failed.storage.records.get(a.id)!.entry.next_block).toBe(0);
  });
  it("restarts a generation-changed LIST snapshot and bounds continuous changes", async () => {
    const storage = new DemoStorage(),
      l = new DemoLink(storage, {}, 0),
      a = score(),
      b = score("02");
    await run(l, a);
    await run(l, b);
    let once = false;
    const changed = new DemoLink(
      storage,
      {
        after: (type) => {
          if (type === CMD.LIST && !once) {
            once = true;
            storage.localDelete(b.id);
          }
        },
      },
      0,
    );
    expect((await listEntries(changed)).map((e) => e.id)).toEqual([a.id]);
    await run(l, b);
    const churn = new DemoLink(
      storage,
      {
        before: (type) => {
          if (type === CMD.LIST) storage.changed();
        },
      },
      0,
    );
    await expect(listEntries(churn)).rejects.toThrow("连续变化");
  });
});
