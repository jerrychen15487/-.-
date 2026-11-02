import { parseScore, uuidBytes, type Score } from "./pseq";
import { BLOCK_BYTES, CMD, ERR, isId } from "./protocol";
import { jsonBytes } from "./wire";
import {
  ensure,
  DeviceError,
  listEntries,
  validateStatus,
  type DeviceLink,
  type Caps,
  type Entry,
  type Progress,
} from "./device-contract";
export * from "./device-contract";
export { BleLink } from "./ble";
export { DemoLink, DemoStorage } from "./demo";

export class TransferPaused extends Error {
  constructor(readonly savedBytes: number) {
    super("已暂停，进度保留");
  }
}
export class TransferStopped extends Error {
  constructor() {
    super("设备离开管理状态，已停止排新块；请回到管理状态后手动续传");
  }
}
export class UnknownCommit extends Error {
  constructor(readonly score: Score) {
    super("最终保存结果未确认；重连后将按 UUID、长度、CRC 和完整状态核对");
  }
}
export class UnknownDelete extends Error {
  constructor(readonly entry: Entry) {
    super("删除结果未确认；重连后先查目录，不会自动重放删除");
  }
}
export const matchesScore = (entry: Entry, score: Score) =>
  entry.id === score.id &&
  entry.total_bytes === score.bytes.length &&
  entry.file_crc === score.crc;
export function validateProgress(
  r: Progress,
  type: number,
  score: Score,
  next?: number,
): Progress {
  const blocks = Math.ceil(score.bytes.length / BLOCK_BYTES);
  ensure(
    r &&
      r.request_type === type &&
      r.id === score.id &&
      Number.isInteger(r.next_block) &&
      r.next_block >= 0 &&
      r.next_block <= blocks &&
      r.total_blocks === blocks &&
      r.saved_bytes ===
        Math.min(r.next_block * BLOCK_BYTES, score.bytes.length) &&
      (next === undefined || r.next_block === next),
    "设备确认进度与曲目不匹配",
  );
  return r;
}
export function dataPayload(score: Score, index: number): Uint8Array {
  const data = score.bytes.subarray(
    index * BLOCK_BYTES,
    Math.min((index + 1) * BLOCK_BYTES, score.bytes.length),
  );
  const b = new Uint8Array(20 + data.length);
  b.set(uuidBytes(score.id));
  new DataView(b.buffer).setUint32(16, index, true);
  b.set(data, 20);
  return b;
}
/** Validate a parsed package before any destructive replacement operation. */
export function validateDeviceSupport(score: Score, caps: Caps): void {
  if (
    score.bytes.length > caps.max_file_bytes ||
    score.notes.length > caps.max_notes ||
    score.pages.length > caps.max_pages ||
    score.sectionCount > caps.max_sections
  )
    throw Error("曲目超过设备能力上限");
  if (score.pages.some((p) => !caps.profiles.includes(p.profile)))
    throw Error("设备不支持曲目谱面 profile");
}
export async function transferScore(
  link: DeviceLink,
  input: Score,
  caps: Caps,
  signal: AbortSignal,
  progress: (savedBytes: number, stage: string) => void,
): Promise<void> {
  const score = parseScore(input.bytes),
    blocks = Math.ceil(score.bytes.length / BLOCK_BYTES);
  const status = validateStatus(await link.request(CMD.STATUS));
  if (status.mode !== 0) throw new TransferStopped();
  validateDeviceSupport(score, caps);
  if (signal.aborted) throw Error("传输尚未开始");
  let accepted = false,
    committing = false,
    pausing = false,
    saved = 0;
  const pause = async () => {
    if (signal.reason === "mode") throw new TransferStopped();
    pausing = true;
    let confirmed: number;
    try {
      confirmed = validateProgress(
        await link.request<Progress>(CMD.PAUSE, jsonBytes({ id: score.id })),
        CMD.PAUSE,
        score,
      ).saved_bytes;
    } catch (e) {
      if (e instanceof DeviceError || link.closed) throw e;
      const st = validateStatus(await link.request(CMD.STATUS));
      const entry = (await listEntries(link)).find((e) =>
        matchesScore(e, score),
      );
      if (st.active_id === score.id || !entry)
        throw Error("暂停结果未确认，请刷新目录核对");
      confirmed = Math.min(entry.next_block * BLOCK_BYTES, entry.total_bytes);
    }
    progress(confirmed, "已暂停，进度保留");
    throw new TransferPaused(confirmed);
  };
  try {
    // BEGIN owns reservation and persistent offset. Never demand another whole
    // file worth of free space when resuming an already reserved partial record.
    accepted = true;
    const begin = validateProgress(
      await link.request<Progress>(
        CMD.BEGIN,
        jsonBytes({
          id: score.id,
          total_bytes: score.bytes.length,
          file_crc: score.crc,
          block_bytes: BLOCK_BYTES,
          package_major: 2,
          total_blocks: blocks,
          capabilities: score.capabilities,
          title: score.meta.title,
        }),
      ),
      CMD.BEGIN,
      score,
    );
    saved = begin.saved_bytes;
    progress(saved, "正在传输");
    for (let block = begin.next_block; block < blocks; block++) {
      if (signal.aborted) await pause();
      const ack = validateProgress(
        await link.request<Progress>(CMD.DATA, dataPayload(score, block)),
        CMD.DATA,
        score,
        block + 1,
      );
      saved = ack.saved_bytes;
      progress(saved, "正在传输");
    }
    if (signal.aborted) await pause();
    committing = true;
    progress(saved, "校验中");
    try {
      const done = await link.request<{
        request_type: number;
        id: string;
        file_crc: number;
        entry_state: number;
      }>(
        CMD.COMMIT,
        jsonBytes({
          id: score.id,
          total_bytes: score.bytes.length,
          file_crc: score.crc,
        }),
        30000,
      );
      ensure(
        done &&
          done.request_type === CMD.COMMIT &&
          done.id === score.id &&
          done.file_crc === score.crc &&
          done.entry_state === 2,
        "COMMIT 应答与曲目不匹配",
      );
    } catch (e) {
      if (e instanceof DeviceError) throw e;
      if (
        link.closed ||
        !(await listEntries(link).catch(() => [])).some(
          (entry) => entry.entry_state === 2 && matchesScore(entry, score),
        )
      )
        throw new UnknownCommit(score);
    }
    progress(score.bytes.length, "已保存");
  } catch (e) {
    if (
      e instanceof TransferPaused ||
      e instanceof TransferStopped ||
      committing ||
      pausing
    )
      throw e;
    if (accepted && signal.aborted) {
      if (signal.reason === "mode") throw new TransferStopped();
      try {
        await pause();
      } catch (pauseError) {
        if (pauseError instanceof TransferPaused) throw pauseError;
        throw Error("暂停结果未确认；设备中的已保存进度请重连后查询");
      }
    }
    throw e;
  }
}
export async function deleteEntry(
  link: DeviceLink,
  entry: Entry,
): Promise<void> {
  if (!isId(entry.id)) throw Error("非法曲目身份");
  const status = validateStatus(await link.request(CMD.STATUS));
  if (status.mode !== 0)
    throw new DeviceError(ERR.BUSY, null, "设备不在曲库管理状态");
  try {
    const r = await link.request<{
      request_type: number;
      id: string;
      deleted: boolean;
    }>(CMD.DELETE, jsonBytes({ id: entry.id }));
    ensure(
      r &&
        r.request_type === CMD.DELETE &&
        r.id === entry.id &&
        typeof r.deleted === "boolean",
      "DELETE 应答格式错误",
    );
  } catch (e) {
    if (e instanceof DeviceError) throw e;
    if (!link.closed) {
      const entries = await listEntries(link).catch(() => undefined);
      if (entries && !entries.some((x) => x.id === entry.id)) return;
    }
    throw new UnknownDelete(entry);
  }
}
