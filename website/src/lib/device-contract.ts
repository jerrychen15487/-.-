import {
  BLOCK_BYTES, MAX_PAYLOAD, CMD, ERR, isId, isU32, validTitle,
} from "./protocol";
import { jsonBytes } from "./wire";
export type Caps = {
  request_type: number;
  protocol: number;
  package_major: number;
  uart_version: number;
  max_payload: number;
  block_bytes: number;
  max_write: number;
  max_file_bytes: number;
  max_notes: number;
  max_complete_songs: number;
  max_partial_songs: number;
  max_sections: number;
  max_pages: number;
  storage_flags: number;
  profile_count: number;
  profiles: number[];
};
export type Changed = { generation: number; mode: number; phase: number };
export type Status = Changed & {
  request_type: number;
  free_bytes: bigint;
  active_id: string | null;
  next_block: number;
  total_blocks: number;
};
export type Entry = {
  id: string;
  title: string;
  entry_state: number;
  total_bytes: number;
  file_crc: number;
  capabilities: number;
  next_block: number;
  total_blocks: number;
};
export type Progress = {
  request_type: number;
  id: string;
  next_block: number;
  total_blocks: number;
  saved_bytes: number;
};
export interface DeviceLink {
  kind: "demo" | "ble";
  name: string;
  readonly identity: string;
  closed: boolean;
  request<T>(type: number, payload?: Uint8Array, timeout?: number): Promise<T>;
  close(): void;
  onDisconnect?: () => void;
  onChanged?: (event: Changed) => void;
}
export class DeviceError extends Error {
  constructor(
    readonly code: number,
    readonly nextBlock: number | null = null,
    message = "设备拒绝请求",
  ) {
    super(
      `${Object.entries(ERR).find(([, v]) => v === code)?.[0] ?? code}：${message}`,
    );
  }
}
export class TransportError extends Error {
  constructor(
    readonly code:
      "ACK_TIMEOUT" | "WRITE_TIMEOUT" | "DISCONNECTED" | "INVALID_REPLY",
    message: string,
  ) {
    super(message);
  }
}
export function ensure(value: unknown, message: string): asserts value {
  if (!value) throw new TransportError("INVALID_REPLY", message);
}
export function validateChanged(x: Changed): Changed {
  ensure(
    x &&
      isU32(x.generation) &&
      x.generation > 0 &&
      Number.isInteger(x.mode) &&
      x.mode >= 0 &&
      x.mode <= 3 &&
      Number.isInteger(x.phase) &&
      x.phase >= 0 &&
      x.phase <= 2,
    "设备模式通知错误",
  );
  return x;
}
export function validateCaps(x: Caps): Caps {
  ensure(
    x &&
      x.request_type === CMD.CAPS &&
      x.protocol === 2 &&
      x.package_major === 2 &&
      x.uart_version === 2 &&
      x.max_payload === MAX_PAYLOAD &&
      x.block_bytes === BLOCK_BYTES &&
      isU32(x.max_write) &&
      x.max_write >= 20 &&
      x.max_write <= 512,
    "设备协议版本或分片能力不兼容",
  );
  ensure(
    [
      x.max_file_bytes,
      x.max_notes,
      x.max_complete_songs,
      x.max_partial_songs,
      x.max_sections,
      x.max_pages,
    ].every((n) => isU32(n) && n > 0) &&
      isU32(x.storage_flags) &&
      x.storage_flags & 1 &&
      Array.isArray(x.profiles) &&
      x.profile_count === x.profiles.length &&
      x.profiles.length <= 32 &&
      new Set(x.profiles).size === x.profiles.length &&
      x.profiles.every((n) => Number.isInteger(n) && n > 0 && n <= 65535),
    "设备容量或持久化能力错误",
  );
  return x;
}
export function validateStatus(value: unknown): Status {
  const x = value as Omit<Status, "free_bytes"> & { free_bytes: unknown };
  validateChanged(x);
  ensure(
    x.request_type === CMD.STATUS &&
      typeof x.free_bytes === "string" &&
      /^(0|[1-9]\d{0,19})$/.test(x.free_bytes),
    "容量必须是十进制 u64 字符串",
  );
  const free = BigInt(x.free_bytes);
  ensure(free <= 0xffffffffffffffffn, "容量超过 u64");
  ensure(
    (x.active_id === null || isId(x.active_id)) &&
      isU32(x.next_block) &&
      isU32(x.total_blocks) &&
      x.next_block <= x.total_blocks,
    "活动传输字段错误",
  );
  ensure(
    x.active_id !== null || (x.next_block === 0 && x.total_blocks === 0),
    "无活动曲目时块数必须为零",
  );
  return { ...x, free_bytes: free };
}
export function validateEntry(e: Entry): Entry {
  ensure(
    e &&
      isId(e.id) &&
      validTitle(e.title) &&
      [1, 2].includes(e.entry_state) &&
      isU32(e.total_bytes) &&
      e.total_bytes >= 64 &&
      isU32(e.file_crc) &&
      isU32(e.capabilities) &&
      e.capabilities > 0 &&
      !(e.capabilities & ~7) &&
      isU32(e.next_block) &&
      e.total_blocks === Math.ceil(e.total_bytes / BLOCK_BYTES) &&
      e.next_block <= e.total_blocks &&
      (e.entry_state !== 2 || e.next_block === e.total_blocks),
    "设备目录条目错误",
  );
  return e;
}
export async function listEntries(link: DeviceLink): Promise<Entry[]> {
  for (let round = 0; round < 3; round++) {
    let cursor = 0,
      generation = 0;
    const result: Entry[] = [],
      ids = new Set<string>(),
      cursors = new Set<number>([0]);
    try {
      for (let page = 0; page < 65536; page++) {
        const r = await link.request<{
          request_type: number;
          generation: number;
          next_cursor: number | null;
          items: Entry[];
        }>(CMD.LIST, jsonBytes({ generation, cursor, limit: 1 }));
        ensure(
          r &&
            r.request_type === CMD.LIST &&
            isU32(r.generation) &&
            r.generation > 0 &&
            Array.isArray(r.items) &&
            r.items.length <= 1,
          "设备目录响应错误",
        );
        if (generation && generation !== r.generation)
          throw new DeviceError(ERR.STALE_LIST);
        generation = r.generation;
        for (const e of r.items) {
          validateEntry(e);
          ensure(!ids.has(e.id), "设备目录 UUID 重复");
          ids.add(e.id);
          result.push(e);
        }
        if (r.next_cursor === null) return result;
        ensure(
          isU32(r.next_cursor) &&
            !cursors.has(r.next_cursor) &&
            r.items.length === 1,
          "设备目录游标错误",
        );
        cursors.add(r.next_cursor);
        cursor = r.next_cursor;
      }
      throw Error("设备目录超过分页安全上限");
    } catch (e) {
      if (!(e instanceof DeviceError && e.code === ERR.STALE_LIST)) throw e;
    }
  }
  throw Error("设备目录连续变化，请稍后刷新");
}
