import { crc32, parseScore, uuid } from "./pseq";
import {
  BLOCK_BYTES, MAX_PAYLOAD, CMD, ERR, isId, isU32, validTitle,
} from "./protocol";
import { readJson } from "./wire";
import {
  DeviceError,
  TransportError,
  type Caps,
  type Changed,
  type DeviceLink,
  type Entry,
} from "./device-contract";

type Stored = { entry: Entry; bytes: Uint8Array };
export class DemoStorage {
  readonly identity = crypto.randomUUID();
  readonly records = new Map<string, Stored>();
  readonly listeners = new Set<(event: Changed) => void>();
  generation = 1;
  mode = 0;
  phase = 0;
  activeId: string | null = null;
  capacity = 8 * 1048576;
  readonly caps: Caps = {
    request_type: CMD.CAPS,
    protocol: 2,
    package_major: 2,
    uart_version: 2,
    max_payload: MAX_PAYLOAD,
    block_bytes: BLOCK_BYTES,
    max_write: 128,
    max_file_bytes: 4 * 1048576,
    max_notes: 20000,
    max_complete_songs: 16,
    max_partial_songs: 4,
    max_sections: 128,
    max_pages: 64,
    storage_flags: 1,
    profile_count: 1,
    profiles: [1],
  };
  changed(directory = true) {
    if (directory)
      this.generation =
        this.generation === 0xffffffff ? 1 : this.generation + 1;
    const event = {
      generation: this.generation,
      mode: this.mode,
      phase: this.phase,
    };
    for (const listener of this.listeners) listener(event);
  }
  setMode(mode: number) {
    if (!Number.isInteger(mode) || mode < 0 || mode > 3)
      throw Error("演示模式错误");
    this.mode = mode;
    if (mode !== 0) {
      this.activeId = null;
      this.phase = 0;
    }
    this.changed(false);
  }
  restart() {
    this.activeId = null;
    this.phase = 0;
    this.changed(false);
  }
  localDelete(id: string) {
    if (this.mode !== 0) throw new DeviceError(ERR.BUSY);
    if (this.records.delete(id)) {
      if (this.activeId === id) {
        this.activeId = null;
        this.phase = 0;
      }
      this.changed();
    }
  }
  get freeBytes() {
    return (
      this.capacity -
      [...this.records.values()].reduce(
        (sum, r) => sum + r.entry.total_bytes,
        0,
      )
    );
  }
}
export type DemoFaults = {
  before?: (type: number) => void | Promise<void>;
  after?: (type: number, result: unknown) => void | Promise<void>;
};
/** Browser-only test storage: survives link objects, never claims disk/FPGA persistence. */
export class DemoLink implements DeviceLink {
  kind = "demo" as const;
  name = "演示设备 · 当前浏览器内存";
  closed = false;
  onDisconnect?: () => void;
  onChanged?: (event: Changed) => void;
  private queue: Promise<unknown> = Promise.resolve();
  private listener = (event: Changed) => {
    this.onChanged?.(event);
  };
  constructor(
    readonly storage = new DemoStorage(),
    readonly faults: DemoFaults = {},
    readonly latency = 8,
  ) {
    storage.listeners.add(this.listener);
  }
  get identity() {
    return this.storage.identity;
  }
  request<T>(type: number, payload = new Uint8Array()): Promise<T> {
    const bytes = payload.slice();
    const result = this.queue.then(async () => {
      if (this.latency)
        await new Promise((r) =>
          setTimeout(r, type === CMD.COMMIT ? 100 : this.latency),
        );
      if (this.closed)
        throw new TransportError("DISCONNECTED", "演示设备已断开");
      await this.faults.before?.(type);
      const value = this.execute(type, bytes);
      await this.faults.after?.(type, value);
      return value as T;
    });
    this.queue = result.catch(() => {});
    return result;
  }
  private execute(type: number, payload: Uint8Array): unknown {
    const s = this.storage;
    const requireManagement = () => {
      if (s.mode !== 0)
        throw new DeviceError(ERR.BUSY, null, "设备不在曲库管理状态");
    };
    const progress = (r: Stored) => ({
      request_type: type,
      id: r.entry.id,
      next_block: r.entry.next_block,
      total_blocks: r.entry.total_blocks,
      saved_bytes: Math.min(
        r.entry.next_block * BLOCK_BYTES,
        r.entry.total_bytes,
      ),
    });
    const object = () => {
      try {
        const r = readJson<Record<string, unknown>>(payload);
        if (!r || typeof r !== "object" || Array.isArray(r)) throw Error();
        return r;
      } catch {
        throw new DeviceError(ERR.BAD_REQUEST);
      }
    };
    if (payload.length > MAX_PAYLOAD) throw new DeviceError(ERR.BAD_REQUEST);
    switch (type) {
      case CMD.CAPS:
        return { ...s.caps, profiles: [...s.caps.profiles] };
      case CMD.STATUS: {
        const r = s.activeId ? s.records.get(s.activeId) : undefined;
        return {
          request_type: type,
          generation: s.generation,
          mode: s.mode,
          phase: s.phase,
          free_bytes: String(s.freeBytes),
          active_id: r?.entry.id ?? null,
          next_block: r?.entry.next_block ?? 0,
          total_blocks: r?.entry.total_blocks ?? 0,
        };
      }
      case CMD.LIST: {
        const p = object();
        if (!isU32(p.generation) || !isU32(p.cursor) || p.limit !== 1)
          throw new DeviceError(ERR.BAD_REQUEST);
        if (p.generation && p.generation !== s.generation)
          throw new DeviceError(ERR.STALE_LIST);
        const rows = [...s.records.values()];
        if (p.cursor > rows.length) throw new DeviceError(ERR.BAD_REQUEST);
        return {
          request_type: type,
          generation: s.generation,
          next_cursor: p.cursor + 1 < rows.length ? p.cursor + 1 : null,
          items: rows
            .slice(p.cursor, p.cursor + 1)
            .map((r) => ({ ...r.entry })),
        };
      }
      case CMD.BEGIN: {
        requireManagement();
        const p = object();
        if (
          !isId(p.id) ||
          !validTitle(p.title) ||
          !isU32(p.total_bytes) ||
          p.total_bytes < 64 ||
          !isU32(p.file_crc) ||
          p.block_bytes !== BLOCK_BYTES ||
          p.package_major !== 2 ||
          p.total_blocks !== Math.ceil(p.total_bytes / BLOCK_BYTES) ||
          !isU32(p.capabilities) ||
          p.capabilities < 1 ||
          p.capabilities & ~7
        )
          throw new DeviceError(ERR.BAD_REQUEST);
        if (s.activeId && s.activeId !== p.id) throw new DeviceError(ERR.BUSY);
        let r = s.records.get(p.id);
        if (r?.entry.entry_state === 2)
          throw new DeviceError(ERR.ALREADY_STORED);
        if (
          r &&
          (r.entry.total_bytes !== p.total_bytes ||
            r.entry.file_crc !== p.file_crc ||
            r.entry.capabilities !== p.capabilities)
        )
          throw new DeviceError(ERR.CONTENT_MISMATCH);
        if (!r) {
          if (
            p.total_bytes > s.caps.max_file_bytes ||
            p.total_bytes > s.freeBytes ||
            [...s.records.values()].filter((r) => r.entry.entry_state === 1)
              .length >= s.caps.max_partial_songs
          )
            throw new DeviceError(ERR.NO_SPACE);
          r = {
            entry: {
              id: p.id,
              title: p.title,
              total_bytes: p.total_bytes,
              file_crc: p.file_crc,
              capabilities: p.capabilities,
              total_blocks: p.total_blocks as number,
              next_block: 0,
              entry_state: 1,
            },
            bytes: new Uint8Array(p.total_bytes),
          };
          s.records.set(p.id, r);
          s.activeId = p.id;
          s.phase = 1;
          s.changed();
        } else {
          s.activeId = p.id;
          s.phase = 1;
          s.changed(false);
        }
        return progress(r);
      }
      case CMD.DATA: {
        requireManagement();
        if (payload.length < 21 || payload.length > 20 + BLOCK_BYTES)
          throw new DeviceError(ERR.BAD_REQUEST);
        const id = uuid(payload.subarray(0, 16));
        if (!isId(id)) throw new DeviceError(ERR.BAD_REQUEST);
        const index = new DataView(
            payload.buffer,
            payload.byteOffset,
            payload.byteLength,
          ).getUint32(16, true),
          r = s.records.get(id);
        if (!r || s.activeId !== id || r.entry.entry_state !== 1)
          throw new DeviceError(ERR.BAD_BLOCK);
        const length = Math.min(
            BLOCK_BYTES,
            r.entry.total_bytes - index * BLOCK_BYTES,
          ),
          data = payload.subarray(20);
        if (
          index >= r.entry.total_blocks ||
          data.length !== length ||
          index > r.entry.next_block
        )
          throw new DeviceError(ERR.BAD_BLOCK, r.entry.next_block);
        if (index < r.entry.next_block) {
          if (!data.every((b, i) => b === r.bytes[index * BLOCK_BYTES + i]))
            throw new DeviceError(ERR.CONTENT_MISMATCH);
          return progress(r);
        }
        r.bytes.set(data, index * BLOCK_BYTES);
        r.entry.next_block++;
        return progress(r);
      }
      case CMD.PAUSE: {
        const p = object();
        if (!isId(p.id)) throw new DeviceError(ERR.BAD_REQUEST);
        const r = s.records.get(p.id);
        if (!r) throw new DeviceError(ERR.NOT_FOUND);
        if (s.activeId === p.id) {
          s.activeId = null;
          s.phase = 0;
          s.changed(false);
        }
        return progress(r);
      }
      case CMD.COMMIT: {
        requireManagement();
        const p = object();
        if (!isId(p.id)) throw new DeviceError(ERR.BAD_REQUEST);
        const r = s.records.get(p.id);
        if (!r) throw new DeviceError(ERR.NOT_FOUND);
        if (
          r.entry.total_bytes !== p.total_bytes ||
          r.entry.file_crc !== p.file_crc
        )
          throw new DeviceError(ERR.CONTENT_MISMATCH);
        if (r.entry.entry_state === 1) {
          if (s.activeId !== p.id) throw new DeviceError(ERR.BUSY);
          if (
            r.entry.next_block !== r.entry.total_blocks ||
            crc32(r.bytes) !== r.entry.file_crc
          )
            throw new DeviceError(ERR.BAD_FILE_CRC);
          if (
            [...s.records.values()].filter((r) => r.entry.entry_state === 2)
              .length >= s.caps.max_complete_songs
          )
            throw new DeviceError(ERR.NO_SPACE);
          let score;
          try {
            score = parseScore(r.bytes);
          } catch {
            throw new DeviceError(ERR.BAD_PACKAGE);
          }
          if (
            score.id !== p.id ||
            score.capabilities !== r.entry.capabilities ||
            score.notes.length > s.caps.max_notes ||
            score.pages.length > s.caps.max_pages ||
            score.sectionCount > s.caps.max_sections
          )
            throw new DeviceError(ERR.BAD_PACKAGE);
          s.phase = 2;
          s.changed(false);
          r.entry.entry_state = 2;
          s.activeId = null;
          s.phase = 0;
          s.changed();
        }
        return {
          request_type: type,
          id: p.id,
          file_crc: r.entry.file_crc,
          entry_state: 2,
        };
      }
      case CMD.DELETE: {
        requireManagement();
        const p = object();
        if (!isId(p.id)) throw new DeviceError(ERR.BAD_REQUEST);
        const deleted = s.records.delete(p.id);
        if (s.activeId === p.id) {
          s.activeId = null;
          s.phase = 0;
        }
        if (deleted) s.changed();
        return { request_type: type, id: p.id, deleted };
      }
      default:
        throw new DeviceError(ERR.BAD_REQUEST);
    }
  }
  close() {
    if (this.closed) return;
    this.closed = true;
    this.storage.listeners.delete(this.listener);
    this.storage.restart();
    this.onDisconnect?.();
  }
}
