import {
  validateCaps,
  validateChanged,
  DeviceError,
  TransportError,
  ensure,
  type Changed,
  type Caps,
  type DeviceLink,
} from "./device-contract";
import {
  CMD,
  SERVICE,
  RX,
  TX,
  FrameDecoder,
  encodeFrame,
  readJson,
  type Frame,
} from "./wire";
import { isU32 } from "./protocol";
export class BleLink implements DeviceLink {
  get identity() {
    return this.device?.id ?? "";
  }
  kind = "ble" as const;
  name = "蓝牙设备";
  onDisconnect?: () => void;
  onChanged?: (event: Changed) => void;
  closed = false;
  private queue: Promise<unknown> = Promise.resolve();
  private device?: BluetoothDevice;
  private rx?: BluetoothRemoteGATTCharacteristic;
  private tx?: BluetoothRemoteGATTCharacteristic;
  private decoder = new FrameDecoder();
  private seq = 0;
  private session = crypto.getRandomValues(new Uint32Array(1))[0]! || 1;
  private pending?: {
    seq: number;
    type: number;
    resolve: (f: Frame) => void;
    reject: (e: Error) => void;
  };
  private interrupt?: (error: Error) => void;
  private maxWrite = 20;
  private bulkWriteProbed = false;
  private disconnected = () => {
    if (this.closed) return;
    this.closed = true;
    this.rx = undefined;
    const error = new TransportError(
      "DISCONNECTED",
      "蓝牙连接已断开；请重连后核对曲库",
    );
    this.interrupt?.(error);
    this.pending?.reject(error);
    this.pending = undefined;
    this.decoder.reset();
    this.onDisconnect?.();
  };
  private notification = (event: Event) => {
    const value = (event.target as BluetoothRemoteGATTCharacteristic).value;
    if (!value) return;
    let frames: Frame[];
    try {
      frames = this.decoder.push(
        new Uint8Array(value.buffer, value.byteOffset, value.byteLength),
      );
    } catch {
      this.decoder.reset();
      this.pending?.reject(new TransportError("INVALID_REPLY", "通知数据过长"));
      return;
    }
    for (const f of frames) {
      if (f.type === CMD.CHANGED && f.session === 0 && f.seq === 0) {
        try {
          const changed = validateChanged(readJson<Changed>(f.payload));
          this.onChanged?.(changed);
        } catch {
          /* Unsolicited malformed notifications never resolve a request. */
        }
        continue;
      }
      if (f.session !== this.session || f.seq !== this.pending?.seq) continue;
      try {
        const reply = readJson<{ request_type: number }>(f.payload);
        ensure(
          (f.type === CMD.ACK || f.type === CMD.ERROR) &&
            reply?.request_type === this.pending.type,
          "应答 request_type 或帧类型不匹配",
        );
        this.pending.resolve(f);
      } catch (e) {
        this.pending?.reject(e instanceof Error ? e : new Error(String(e)));
      }
    }
  };
  async connect() {
    this.closed = false;
    this.maxWrite = 20;
    this.bulkWriteProbed = false;
    if (!window.isSecureContext || !navigator.bluetooth)
      throw Error(
        "请使用 HTTPS 下的 Windows / Android Chrome；当前浏览器不支持 Web Bluetooth",
      );
    this.device = await navigator.bluetooth.requestDevice({
      filters: [{ services: [SERVICE] }],
    });
    this.name = this.device.name || "钢琴设备";
    try {
      this.device.addEventListener("gattserverdisconnected", this.disconnected);
      const server = await this.device.gatt!.connect(),
        service = await server.getPrimaryService(SERVICE);
      this.rx = await service.getCharacteristic(RX);
      this.tx = await service.getCharacteristic(TX);
      this.tx.addEventListener("characteristicvaluechanged", this.notification);
      await this.tx.startNotifications();
      const caps = validateCaps(await this.request<Caps>(CMD.CAPS));
      this.maxWrite = caps.max_write;
      return caps;
    } catch (e) {
      this.close();
      throw e;
    }
  }
  request<T>(
    type: number,
    payload = new Uint8Array(),
    timeout = type === CMD.COMMIT ? 30000 : 5000,
  ): Promise<T> {
    const bytes = payload.slice();
    const operation = this.queue.then(() =>
      this.perform<T>(type, bytes, timeout),
    );
    this.queue = operation.catch(() => {});
    return operation;
  }
  private async perform<T>(
    type: number,
    payload = new Uint8Array(),
    timeout = 5000,
  ): Promise<T> {
    if (this.closed || !this.rx || !this.device?.gatt?.connected)
      throw new TransportError("DISCONNECTED", "设备未连接");
    // The first CAPS can race the central's MTU exchange. Probe once just
    // before the first bulk block, after LIST/STATUS/BEGIN have settled, so a
    // link that grew beyond 20 bytes does not keep using tiny GATT writes.
    // Keep the existing per-block ACK/CRC and retry protocol unchanged.
    if (type === CMD.DATA && this.maxWrite === 20 && !this.bulkWriteProbed) {
      this.bulkWriteProbed = true;
      const refreshed = validateCaps(await this.perform<Caps>(CMD.CAPS));
      this.maxWrite = refreshed.max_write;
    }
    if (this.seq === 0xffffffff) {
      this.seq = 0;
      this.session = crypto.getRandomValues(new Uint32Array(1))[0] || 1;
    }
    const seq = ++this.seq,
      encoded = encodeFrame({ type, payload, seq, session: this.session });
    const stopped = new Promise<never>((_, reject) => {
      this.interrupt = reject;
    });
    stopped.catch(() => {});
    try {
      for (let attempt = 0; ; attempt++) {
        let timer: ReturnType<typeof setTimeout> | undefined;
        const answer = new Promise<Frame>((resolve, reject) => {
          this.pending = { seq, type, resolve, reject };
        });
        answer.catch(() => {});
        try {
          for (let o = 0; o < encoded.length; o += this.maxWrite) {
            try {
              // A native GATT write cannot be cancelled. Drop the connection on
              // failure so no new request can overlap an unfinished write.
              const deadline = new Promise<never>((_, reject) => {
                timer = setTimeout(
                  () =>
                    reject(
                      new TransportError(
                        "WRITE_TIMEOUT",
                        "蓝牙写入超时，请重新连接",
                      ),
                    ),
                  5000,
                );
              });
              await Promise.race([
                this.rx.writeValueWithResponse(
                  encoded.slice(o, o + this.maxWrite),
                ),
                stopped,
                deadline,
              ]);
            } catch (e) {
              this.close();
              throw e;
            } finally {
              clearTimeout(timer);
            }
          }
          timer = setTimeout(
            () =>
              this.pending?.reject(
                new TransportError("ACK_TIMEOUT", "设备应答超时，结果未确认"),
              ),
            timeout,
          );
          const f = await answer;
          if (f.type === CMD.ERROR) {
            const r = readJson<{
              code: number;
              next_block: number | null;
              message?: string;
            }>(f.payload);
            ensure(
              r &&
                isU32(r.code) &&
                r.code >= 1 &&
                r.code <= 13 &&
                (r.next_block === null || isU32(r.next_block)) &&
                (r.message === undefined || typeof r.message === "string"),
              "设备 ERROR 必须使用整数协议错误码",
            );
            throw new DeviceError(r.code, r.next_block, r.message);
          }
          return readJson<T>(f.payload);
        } catch (e) {
          this.decoder.reset();
          if (!(
            e instanceof TransportError &&
            e.code === "ACK_TIMEOUT" &&
            attempt < 2
          ))
            throw e;
        } finally {
          if (timer) clearTimeout(timer);
          this.pending = undefined;
        }
      }
    } finally {
      this.interrupt = undefined;
    }
  }
  close() {
    this.device?.removeEventListener(
      "gattserverdisconnected",
      this.disconnected,
    );
    this.tx?.removeEventListener(
      "characteristicvaluechanged",
      this.notification,
    );
    this.device?.gatt?.disconnect();
    this.disconnected();
  }
}
