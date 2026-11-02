import { isId } from "./protocol";

export function crc32(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (const b of bytes) {
    crc ^= b;
    for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}
export function uuid(bytes: Uint8Array): string {
  const h = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
export function uuidBytes(id: string): Uint8Array {
  if (!isId(id.toLowerCase()))
    throw Error("曲目 ID 格式错误");
  return Uint8Array.from(id.replaceAll("-", "").match(/../g)!, (h) =>
    parseInt(h, 16),
  );
}
export function formatBytes(value: number | bigint): string {
  const n = typeof value === "bigint" ? value : BigInt(value);
  for (const [unit, name] of [
    [1099511627776n, "TiB"],
    [1073741824n, "GiB"],
    [1048576n, "MiB"],
    [1024n, "KiB"],
  ] as const)
    if (n >= unit) return `${Number((n * 10n) / unit) / 10} ${name}`;
  return `${n} B`;
}
export const formatTime = (ms: number) =>
  `${Math.floor(ms / 60000)}:${String(Math.floor(ms / 1000) % 60).padStart(2, "0")}`;
