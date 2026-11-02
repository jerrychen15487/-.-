import { crc32 } from "./binary";
import { CMD, VERSION, MAX_PAYLOAD, isU32 } from "./protocol";
export { CMD };
export const SERVICE = "e6340001-8d7a-4e31-9ab0-43c800000001";
export const RX = "e6340002-8d7a-4e31-9ab0-43c800000001";
export const TX = "e6340003-8d7a-4e31-9ab0-43c800000001";
export type Frame = {
  type: number;
  session: number;
  seq: number;
  payload: Uint8Array;
};
export function jsonBytes(value: unknown) {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  if (bytes.length > MAX_PAYLOAD) throw Error("控制 JSON 超过 1024 字节");
  return bytes;
}
export function readJson<T>(bytes: Uint8Array): T {
  return JSON.parse(
    new TextDecoder("utf-8", { fatal: true }).decode(bytes),
  ) as T;
}
export function encodeFrame(f: Frame): Uint8Array {
  if (
    f.payload.length > MAX_PAYLOAD ||
    !isU32(f.seq) ||
    !isU32(f.session) ||
    !Number.isInteger(f.type) ||
    f.type < 0 ||
    f.type > 255
  )
    throw Error("通信帧过长");
  const b = new Uint8Array(20 + f.payload.length),
    v = new DataView(b.buffer);
  b.set([0xa5, 0x5a, VERSION, f.type]);
  v.setUint32(4, f.session, true);
  v.setUint32(8, f.seq, true);
  v.setUint16(12, f.payload.length, true);
  b.set(f.payload, 16);
  v.setUint32(b.length - 4, crc32(b.subarray(2, b.length - 4)), true);
  return b;
}
export class FrameDecoder {
  private data = new Uint8Array(0);
  reset() {
    this.data = new Uint8Array(0);
  }
  push(chunk: Uint8Array): Frame[] {
    if (chunk.length > 65536) throw Error("通知数据过长");
    const b = new Uint8Array(this.data.length + chunk.length);
    b.set(this.data);
    b.set(chunk, this.data.length);
    this.data = b;
    const frames: Frame[] = [];
    while (this.data.length >= 2) {
      const b = this.data;
      if (b[0] !== 0xa5 || b[1] !== 0x5a) {
        this.data = b.slice(1);
        continue;
      }
      if (b.length < 16) break;
      const v = new DataView(b.buffer, b.byteOffset, b.byteLength),
        n = v.getUint16(12, true);
      if (b[2] !== VERSION || n > MAX_PAYLOAD || v.getUint16(14, true) !== 0) {
        this.data = b.slice(1);
        continue;
      }
      if (b.length < n + 20) break;
      if (crc32(b.subarray(2, n + 16)) !== v.getUint32(n + 16, true)) {
        this.data = b.slice(1);
        continue;
      }
      frames.push({
        type: b[3]!,
        session: v.getUint32(4, true),
        seq: v.getUint32(8, true),
        payload: b.slice(16, 16 + n),
      });
      this.data = b.slice(n + 20);
    }
    return frames;
  }
}
