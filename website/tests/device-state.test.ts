import { afterEach, beforeEach, describe, it, expect, vi } from "vitest";
import { readFileSync } from "node:fs";
import { parseScore } from "../src/lib/pseq";
import { CMD } from "../src/lib/wire";
import { ERR } from "../src/lib/protocol";
import type { Caps, Entry } from "../src/lib/device";
import { encodeScore } from "../tools/encode-score";
import { engineeringSource } from "./fixtures/engineering";
import type { useDevice } from "../src/composables/useDevice";
let d: ReturnType<typeof useDevice>;
const score = () =>
  parseScore(
    new Uint8Array(readFileSync("tests/fixtures/packages/engineering.pseq")),
  );
function smallScore(id: string, title: string) {
  const source = engineeringSource();
  source.id = id;
  source.meta.title = title;
  source.durationTicks = 960;
  source.capabilities = 1;
  source.notes = [
    {
      startTick: 0,
      durationTicks: 960,
      pitch: 60,
      dynamic: 4,
      part: 2,
      flags: 7,
      group: 0,
    },
  ];
  source.controls = [];
  source.measures = [
    { index: 0, startTick: 0, endTick: 960, numerator: 4, denominatorPow: 2 },
  ];
  source.pages = [];
  source.anchors = [];
  source.safeStarts = [0];
  return parseScore(encodeScore(source));
}
async function finish(p: Promise<void>) {
  await vi.runAllTimersAsync();
  await p;
  await vi.runAllTimersAsync();
}
beforeEach(async () => {
  vi.resetModules();
  vi.useFakeTimers();
  d = (await import("../src/composables/useDevice")).useDevice();
  await finish(d.connect(true));
});
afterEach(async () => {
  d.disconnect();
  await vi.runAllTimersAsync();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});
describe("visible directory and transfer state", () => {
  it("keeps confirmed storage separate from failed directory refresh", async () => {
    const link = d.link.value!,
      original = link.request.bind(link);
    let committed = false;
    link.request = async (type, payload) => {
      if (type === CMD.LIST && committed) throw Error("LIST_FAILED");
      const r = await original(type, payload);
      if (type === CMD.COMMIT) committed = true;
      return r as never;
    };
    await finish(d.upload(score()));
    expect(d.stage.value).toBe("已保存");
    expect(d.directory.value).toBe("unknown");
    expect(d.error.value).toContain("目录");
  });
  it("reconciles COMMIT after disconnect/reconnect and never calls it cancelled", async () => {
    const uploaded = score();
    const link = d.link.value!,
      original = link.request.bind(link);
    link.request = async (type, payload) => {
      const r = await original(type, payload);
      if (type === CMD.COMMIT) {
        link.close();
        throw Error("disconnected");
      }
      return r as never;
    };
    await finish(d.upload(uploaded));
    expect(d.stage.value).toBe("保存结果未确认");
    expect(d.link.value).toBeUndefined();
    await finish(d.connect(true));
    expect(d.stage.value).toBe("已核对保存成功");
    expect(d.entries.value[0]!.entry_state).toBe(2);
    expect(d.transferTitle.value).toBe(uploaded.meta.title);
    expect(d.transferKind.value).toBe("demo");
    expect(d.savedBytes.value).toBe(uploaded.bytes.length);
    expect(d.totalBytes.value).toBe(uploaded.bytes.length);
    expect(d.progress.value).toBe(100);
  });
  it.each<{ name: string; limits: Partial<Caps> }>([
    { name: "file bytes", limits: { max_file_bytes: 10000 } },
    { name: "note count", limits: { max_notes: 1 } },
    { name: "page count", limits: { max_pages: 1 } },
    { name: "section count", limits: { max_sections: 4 } },
    { name: "profile", limits: { profiles: [], profile_count: 0 } },
  ])("preserves the complete old file when replacement exceeds $name", async ({ limits }) => {
    const replacement = score(),
      old = smallScore(replacement.id, "已保存的旧曲目");
    Object.assign(d.caps.value!, limits);
    await finish(d.upload(old));
    expect(d.entries.value[0]).toMatchObject({
      id: old.id,
      entry_state: 2,
      file_crc: old.crc,
    });
    const link = d.link.value!,
      original = link.request.bind(link),
      calls: number[] = [];
    link.request = async (type, payload) => {
      calls.push(type);
      return original(type, payload) as never;
    };
    await finish(d.upload(replacement, true));
    expect(d.error.value).toMatch(/能力|profile/);
    expect(d.stage.value).toBe("下载未开始");
    expect(calls).not.toContain(CMD.DELETE);
    expect(calls).not.toContain(CMD.BEGIN);
    await finish(d.refresh());
    expect(d.entries.value).toHaveLength(1);
    expect(d.entries.value[0]).toMatchObject({
      id: old.id,
      entry_state: 2,
      total_bytes: old.bytes.length,
      file_crc: old.crc,
    });
  });
  it.each(["magic", "nil UUID"])("rejects a replacement with invalid %s before deleting the complete old package", async (kind) => {
    const replacement = score(),
      old = smallScore(replacement.id, "保留的旧曲目");
    await finish(d.upload(old));
    replacement.bytes = replacement.bytes.slice();
    if (kind === "magic") replacement.bytes[0] = 0;
    else replacement.bytes.fill(0, 12, 28);
    const link = d.link.value!,
      original = link.request.bind(link),
      calls: number[] = [];
    link.request = async (type, payload) => {
      calls.push(type);
      return original(type, payload) as never;
    };
    await finish(d.upload(replacement, true));
    expect(d.error.value).not.toBe("");
    if (kind === "nil UUID") expect(d.error.value).toContain("非法曲目身份");
    expect(d.stage.value).toBe("下载未开始");
    expect(calls).not.toContain(CMD.DELETE);
    expect(calls).not.toContain(CMD.BEGIN);
    await finish(d.refresh());
    expect(d.entries.value).toHaveLength(1);
    expect(d.entries.value[0]).toMatchObject({
      id: old.id,
      entry_state: 2,
      total_bytes: old.bytes.length,
      file_crc: old.crc,
    });
  });
  it("rejects a new nil-header upload before BEGIN", async () => {
    const uploaded = score(), calls: number[] = [];
    uploaded.bytes.fill(0, 12, 28);
    const link = d.link.value!, request = link.request.bind(link);
    link.request = async (type, payload) => { calls.push(type); return request(type, payload) as never; };
    await finish(d.upload(uploaded));
    expect(d.error.value).toContain("非法曲目身份");
    expect(d.stage.value).toBe("下载未开始");
    expect(calls).not.toContain(CMD.BEGIN);
    expect(calls).not.toContain(CMD.DELETE);
    expect(d.entries.value).toEqual([]);
  });
  it("shows a new upload rejected by local capability checks as not started", async () => {
    const uploaded = score(),
      link = d.link.value!,
      original = link.request.bind(link),
      calls: number[] = [];
    d.caps.value!.max_file_bytes = uploaded.bytes.length - 4;
    link.request = async (type, payload) => {
      calls.push(type);
      return original(type, payload) as never;
    };
    await finish(d.upload(uploaded));
    expect(d.error.value).toContain("能力");
    expect(d.stage.value).toBe("下载未开始");
    expect(d.savedBytes.value).toBe(0);
    expect(calls).not.toContain(CMD.BEGIN);
    expect(d.entries.value).toEqual([]);
  });
  it.each([
    { command: CMD.BEGIN, code: ERR.NO_SPACE },
    { command: CMD.COMMIT, code: ERR.BAD_PACKAGE },
  ])("distinguishes explicit device rejection at command $command from unknown storage", async ({ command, code }) => {
    const { DeviceError } = await import("../src/lib/device");
    const uploaded = smallScore("12345678-1234-5678-9abc-def012345678", "明确拒绝"),
      link = d.link.value!,
      original = link.request.bind(link);
    link.request = async (type, payload) => {
      if (type === command) throw new DeviceError(code);
      return original(type, payload) as never;
    };
    await finish(d.upload(uploaded));
    expect(d.error.value).toMatch(/NO_SPACE|BAD_PACKAGE/);
    expect(d.stage.value).toBe("设备拒绝下载");
    expect(d.entries.value.every((entry) => entry.entry_state === 1)).toBe(true);
  });
  it("distinguishes an interrupted DATA request from an unknown COMMIT result", async () => {
    const { TransportError } = await import("../src/lib/device");
    const link = d.link.value!,
      original = link.request.bind(link);
    let blocks = 0;
    link.request = async (type, payload) => {
      if (type === CMD.DATA && ++blocks === 2)
        throw new TransportError("ACK_TIMEOUT", "DATA reply lost");
      return original(type, payload) as never;
    };
    await finish(d.upload(score()));
    expect(d.error.value).toContain("DATA reply lost");
    expect(d.stage.value).toBe("传输中断，请查询设备进度");
    expect(d.savedBytes.value).toBe(512);
    expect(d.entries.value[0]).toMatchObject({ entry_state: 1, next_block: 1 });
  });
  it("keeps a newer CHANGED mode when an older STATUS finishes and the follow-up query fails", async () => {
    const { TransportError } = await import("../src/lib/device");
    const link = d.link.value!,
      original = link.request.bind(link),
      modesAtFollowUp: (number | undefined)[] = [];
    let statuses = 0;
    link.request = async (type, payload) => {
      if (type === CMD.STATUS && ++statuses > 1) {
        modesAtFollowUp.push(d.status.value?.mode);
        throw new TransportError("ACK_TIMEOUT", "STATUS reply lost");
      }
      const result = await original(type, payload);
      if (type === CMD.STATUS) {
        d.toggleDemoState();
        expect(d.status.value?.mode).toBe(3);
      }
      return result as never;
    };
    await finish(d.refresh());
    expect(modesAtFollowUp).toEqual([3]);
    expect(d.status.value?.mode).toBe(3);
    expect(d.directory.value).toBe("unknown");
    expect(d.error.value).toContain("STATUS reply lost");
    expect(d.busy.value).toBe(false);
  });
  it("keeps a CHANGED mode received during LIST when the next STATUS query fails", async () => {
    const { TransportError } = await import("../src/lib/device");
    const link = d.link.value!,
      original = link.request.bind(link),
      modesAtFollowUp: (number | undefined)[] = [];
    let statuses = 0,
      notified = false;
    link.request = async (type, payload) => {
      if (type === CMD.STATUS && ++statuses > 1) {
        modesAtFollowUp.push(d.status.value?.mode);
        throw new TransportError("ACK_TIMEOUT", "STATUS reply lost");
      }
      const result = await original(type, payload);
      if (type === CMD.LIST && !notified) {
        notified = true;
        d.toggleDemoState();
        expect(d.status.value?.mode).toBe(3);
      }
      return result as never;
    };
    await finish(d.refresh());
    expect(notified).toBe(true);
    expect(modesAtFollowUp).toEqual([3]);
    expect(d.status.value?.mode).toBe(3);
    expect(d.directory.value).toBe("unknown");
    expect(d.error.value).toContain("STATUS reply lost");
    expect(d.busy.value).toBe(false);
  });
  it("does not retain a resume source when BEGIN was explicitly rejected", async () => {
    const { DeviceError } = await import("../src/lib/device");
    const uploaded = smallScore("12345678-1234-5678-9abc-def012345678", "未被接受的曲目"),
      link = d.link.value!,
      original = link.request.bind(link);
    const fetchCatalog = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => [],
    });
    vi.stubGlobal("fetch", fetchCatalog);
    link.request = async (type, payload) => {
      if (type === CMD.BEGIN) throw new DeviceError(ERR.NO_SPACE);
      return original(type, payload) as never;
    };
    await finish(d.upload(uploaded));
    expect(d.error.value).toContain("NO_SPACE");
    expect(fetchCatalog).not.toHaveBeenCalled();
    const calls: number[] = [];
    link.request = async (type, payload) => {
      calls.push(type);
      return original(type, payload) as never;
    };
    const staleEntry: Entry = {
      id: uploaded.id,
      title: String(uploaded.meta.title),
      entry_state: 1,
      total_bytes: uploaded.bytes.length,
      file_crc: uploaded.crc,
      capabilities: uploaded.capabilities,
      next_block: 0,
      total_blocks: Math.ceil(uploaded.bytes.length / 512),
    };
    await finish(d.resume(staleEntry));
    expect(fetchCatalog).toHaveBeenCalledOnce();
    expect(fetchCatalog.mock.calls[0]![0]).toMatch(/scores\/catalog\.json$/);
    expect(d.error.value).toContain("重新导入");
    expect(calls).not.toContain(CMD.BEGIN);
  });
  it("uses an accepted source for resume and releases it after confirmed deletion", async () => {
    const uploaded = score(),
      link = d.link.value!,
      original = link.request.bind(link);
    const fetchCatalog = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => [],
    });
    vi.stubGlobal("fetch", fetchCatalog);
    let paused = false;
    link.request = async (type, payload) => {
      if (type === CMD.DATA && !paused) {
        paused = true;
        d.pause();
      }
      return original(type, payload) as never;
    };
    await finish(d.upload(uploaded));
    expect(d.stage.value).toBe("已暂停，进度保留");
    const partial = d.entries.value[0]!;
    expect(partial).toMatchObject({ entry_state: 1, next_block: 1 });
    link.request = original;
    await finish(d.resume(partial));
    expect(fetchCatalog).not.toHaveBeenCalled();
    expect(d.stage.value).toBe("已保存");
    await finish(d.remove(d.entries.value[0]!));
    expect(d.stage.value).toBe("已删除");
    expect(d.entries.value).toEqual([]);
    const calls: number[] = [];
    link.request = async (type, payload) => {
      calls.push(type);
      return original(type, payload) as never;
    };
    await finish(d.resume(partial));
    expect(fetchCatalog).toHaveBeenCalledOnce();
    expect(d.error.value).toContain("重新导入");
    expect(calls).not.toContain(CMD.BEGIN);
  });
  it("does not label rejected B as saved while reconciling A's unknown COMMIT", async () => {
    const { DeviceError, TransportError } = await import("../src/lib/device");
    const a = smallScore("12345678-1234-5678-9abc-def012345601", "曲目 A"),
      b = smallScore("12345678-1234-5678-9abc-def012345602", "曲目 B"),
      link = d.link.value!,
      original = link.request.bind(link);
    let committed = false;
    link.request = async (type, payload) => {
      if (type === CMD.LIST && committed) throw Error("LIST_TEMPORARILY_FAILED");
      const result = await original(type, payload);
      if (type === CMD.COMMIT) {
        committed = true;
        throw new TransportError("ACK_TIMEOUT", "COMMIT reply lost");
      }
      return result as never;
    };
    await finish(d.upload(a));
    expect(d.stage.value).toBe("保存结果未确认");
    link.request = async (type, payload) => {
      if (type === CMD.BEGIN) throw new DeviceError(ERR.NO_SPACE);
      return original(type, payload) as never;
    };
    await finish(d.upload(b));
    expect(d.error.value).toContain("NO_SPACE");
    expect(d.entries.value.map((entry) => entry.id)).toEqual([a.id]);
    expect(d.entries.value[0]!.entry_state).toBe(2);
    expect(d.transferTitle.value).toBe(b.meta.title);
    expect(d.totalBytes.value).toBe(b.bytes.length);
    expect(d.savedBytes.value).toBe(0);
    expect(d.progress.value).toBe(0);
    expect(d.stage.value).not.toMatch(/保存成功|已保存/);
  });
  it.each(["different UUID", "same UUID"])("does not overwrite B's confirmed transfer with A's pending DELETE result (%s)", async (identity) => {
    const { TransportError } = await import("../src/lib/device");
    const a = smallScore("12345678-1234-5678-9abc-def012345601", "曲目 A"),
      b = smallScore(
        identity === "same UUID" ? a.id : "12345678-1234-5678-9abc-def012345602",
        "曲目 B",
      );
    await finish(d.upload(a));
    const entry = d.entries.value[0]!,
      link = d.link.value!,
      original = link.request.bind(link);
    let deleted = false;
    link.request = async (type, payload) => {
      if (type === CMD.LIST && deleted) throw Error("LIST_TEMPORARILY_FAILED");
      const result = await original(type, payload);
      if (type === CMD.DELETE) {
        deleted = true;
        throw new TransportError("ACK_TIMEOUT", "DELETE reply lost");
      }
      return result as never;
    };
    await finish(d.remove(entry));
    expect(d.stage.value).toContain("删除结果未确认");
    link.request = original;
    await finish(d.upload(b));
    expect(d.entries.value.map((row) => row.id)).toEqual([b.id]);
    expect(d.entries.value[0]!.entry_state).toBe(2);
    expect(d.transferTitle.value).toBe(b.meta.title);
    expect(d.totalBytes.value).toBe(b.bytes.length);
    expect(d.savedBytes.value).toBe(b.bytes.length);
    expect(d.progress.value).toBe(100);
    expect(d.stage.value).toBe("已保存");
  });
  it("pauses only after the in-flight block finishes and preserves partial directory state", async () => {
    const link = d.link.value!,
      original = link.request.bind(link);
    let blocks = 0;
    link.request = async (type, payload) => {
      if (type === CMD.DATA && ++blocks === 2) d.pause();
      return original(type, payload) as never;
    };
    await finish(d.upload(score()));
    expect(d.stage.value).toBe("已暂停，进度保留");
    expect(d.entries.value[0]!.entry_state).toBe(1);
    expect(d.entries.value[0]!.next_block).toBe(2);
    expect(d.savedBytes.value).toBe(1024);
    await finish(d.resume(d.entries.value[0]!));
    expect(d.stage.value).toBe("已保存");
  });
  it("keeps the pause-in-progress stage while PAUSE is still waiting for its ACK", async () => {
    const link = d.link.value!,
      original = link.request.bind(link);
    let releasePause!: () => void;
    const waitingForPause = new Promise<void>((resolve) => {
      releasePause = resolve;
    });
    let blocks = 0,
      pauses = 0;
    link.request = async (type, payload) => {
      if (type === CMD.DATA && ++blocks === 1) d.pause();
      if (type === CMD.PAUSE) {
        pauses++;
        await waitingForPause;
      }
      return original(type, payload) as never;
    };
    const sending = d.upload(score());
    try {
      await vi.runAllTimersAsync();
      expect(pauses).toBe(1);
      expect(blocks).toBe(1);
      expect(d.busy.value).toBe(true);
      expect(d.savedBytes.value).toBe(512);
      expect(d.stage.value).toContain("暂停");
      expect(d.stage.value).not.toBe("正在传输");
    } finally {
      releasePause();
      await finish(sending);
    }
    expect(d.stage.value).toBe("已暂停，进度保留");
    expect(d.entries.value[0]).toMatchObject({ entry_state: 1, next_block: 1 });
  });
  it("reconciles an unknown re-download deletion before issuing any new BEGIN", async () => {
    await finish(d.upload(score()));
    const entry = d.entries.value[0]!,
      link = d.link.value!,
      original = link.request.bind(link);
    let begins = 0;
    link.request = async (type, payload) => {
      if (type === CMD.BEGIN) begins++;
      const r = await original(type, payload);
      if (type === CMD.DELETE) {
        link.close();
        throw Error("lost delete result");
      }
      return r as never;
    };
    await finish(d.redownload(entry));
    expect(begins).toBe(0);
    expect(d.stage.value).toContain("删除结果未确认");
    await finish(d.connect(true));
    expect(d.stage.value).toBe("已核对曲目不存在");
    expect(d.entries.value).toEqual([]);
  });
  it("stops on demo local mode notification and waits for explicit resume", async () => {
    const link = d.link.value!,
      original = link.request.bind(link);
    let first = true;
    link.request = async (type, payload) => {
      const r = await original(type, payload);
      if (type === CMD.DATA && first) {
        first = false;
        d.toggleDemoState();
      }
      return r as never;
    };
    await finish(d.upload(score()));
    expect(d.stage.value).toContain("手动续传");
    expect(d.status.value!.mode).toBe(3);
    d.toggleDemoState();
    await vi.runAllTimersAsync();
    expect(d.entries.value[0]!.next_block).toBe(1);
  });
  it("requeries a demo local deletion notification without a remote delete command", async () => {
    await finish(d.upload(score()));
    const link = d.link.value!,
      original = link.request.bind(link),
      calls: number[] = [];
    link.request = async (type, payload) => {
      calls.push(type);
      return original(type, payload) as never;
    };
    d.demoLocalDelete(d.entries.value[0]!);
    await vi.runAllTimersAsync();
    expect(d.directory.value).toBe("known");
    expect(d.entries.value).toEqual([]);
    expect(calls).not.toContain(CMD.DELETE);
  });
});
