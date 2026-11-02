// Source: workspace trans/PROTOCOL.md, 2026-10-11 chapter 3 and appendix A.
export const VERSION = 2;
export const PPQ = 960;
export const BLOCK_BYTES = 512;
export const MAX_PAYLOAD = 1024;
export const CMD = {
  CAPS: 0x01, STATUS: 0x02, LIST: 0x03, BEGIN: 0x10, DATA: 0x11,
  COMMIT: 0x12, PAUSE: 0x13, DELETE: 0x14, ACK: 0x80, CHANGED: 0x90, ERROR: 0xff,
} as const;
export const ERR = {
  BUSY: 1, NO_SPACE: 2, UNSUPPORTED_VERSION: 3, UNSUPPORTED_PROFILE: 4,
  BAD_BLOCK: 5, BAD_FILE_CRC: 6, BAD_PACKAGE: 7, STORAGE_ERROR: 8,
  CONTENT_MISMATCH: 9, NOT_FOUND: 10, STALE_LIST: 11, ALREADY_STORED: 12, BAD_REQUEST: 13,
} as const;
export const SECTION = { META: 1, NOTE: 2, CC: 3, MEASURE: 4, PAGE: 5, BITMAP: 6, ANCHOR: 7, SAFE_START: 8 } as const;
export const RECORD_BYTES: Record<number, number> = {
  [SECTION.META]: 0,
  [SECTION.NOTE]: 16,
  [SECTION.CC]: 8,
  [SECTION.MEASURE]: 16,
  [SECTION.PAGE]: 24,
  [SECTION.BITMAP]: 0,
  [SECTION.ANCHOR]: 24,
  [SECTION.SAFE_START]: 4,
};
export const DYNAMICS = ["未指定", "pp", "p", "mp", "mf", "f", "ff"] as const;
export const MODE_NAMES = ["曲库管理", "自由演奏", "曲谱阅读", "跟谱练习"] as const;
export const isU32 = (x: unknown): x is number => typeof x === "number" && Number.isInteger(x) && x >= 0 && x <= 0xffffffff;
export const isId = (x: unknown): x is string => typeof x === "string" && x !== "00000000-0000-0000-0000-000000000000" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(x);
export const validTitle = (x: unknown): x is string => typeof x === "string" && x.length > 0 &&
  [...x].length <= 128 && new TextEncoder().encode(x).length <= 384 && !/[\u0000-\u001f\ud800-\udfff]/u.test(x);
