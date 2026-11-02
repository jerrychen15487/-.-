import { afterEach, describe, expect, it, vi } from "vitest";
import { BleLink, type Caps } from "../src/lib/device";
import {
  CMD,
  RX,
  FrameDecoder,
  encodeFrame,
  jsonBytes,
  type Frame,
} from "../src/lib/wire";

import { DemoStorage, TransportError } from "../src/lib/device";
const caps: Caps = { ...new DemoStorage().caps, max_write: 64 };
async function bluetooth(initialMaxWrite = 64) {
  const device = new EventTarget();
  const tx = Object.assign(new EventTarget(), {
    value: new DataView(new ArrayBuffer(0)),
    startNotifications: async () => {},
  });
  const frames: Frame[] = [],
    decoder = new FrameDecoder();
  function reply(f: Frame, value: unknown = {}, type: number = CMD.ACK) {
    const bytes = encodeFrame({
      ...f,
      type,
      payload: jsonBytes({ request_type: f.type, ...(value as object) }),
    });
    for (let offset = 0; offset < bytes.length; offset += 7) {
      tx.value = new DataView(bytes.slice(offset, offset + 7).buffer);
      tx.dispatchEvent(new Event("characteristicvaluechanged"));
    }
  }
  const state = {
    caps: { ...caps, max_write: initialMaxWrite },
    handle: (f: Frame) => reply(f),
  };
  const rx = {
    writeValueWithResponse: vi.fn(async (bytes: Uint8Array) => {
      for (const f of decoder.push(bytes)) {
        frames.push(f);
        if (f.type === CMD.CAPS) reply(f, state.caps);
        else state.handle(f);
      }
    }),
  };
  const gatt = {
    connected: false,
    connect: async () => {
      gatt.connected = true;
      return gatt;
    },
    getPrimaryService: async () => ({
      getCharacteristic: async (id: string) => (id === RX ? rx : tx),
    }),
    disconnect: () => {
      gatt.connected = false;
      device.dispatchEvent(new Event("gattserverdisconnected"));
    },
  };
  Object.assign(device, { id: "mock-ble-1", name: "Test BLE", gatt });
  vi.stubGlobal("window", { isSecureContext: true });
  vi.stubGlobal("navigator", {
    bluetooth: { requestDevice: async () => device },
  });
  const link = new BleLink();
  await link.connect();
  return { link, rx, gatt, state, frames, reply };
}
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("real BLE client with mocked GATT", () => {
  it("uses initial 20-byte writes and the reported max_write afterwards", async () => {
    const { link, rx } = await bluetooth();
    expect(rx.writeValueWithResponse.mock.calls[0]![0].length).toBe(20);
    await link.request(CMD.DATA, new Uint8Array(532));
    const lengths = rx.writeValueWithResponse.mock.calls
      .slice(1)
      .map((c) => c[0].length);
    expect(Math.max(...lengths)).toBe(64);
    expect(lengths.reduce((a, b) => a + b, 0)).toBe(552);
    link.close();
  });
  it("rechecks the negotiated write size once before bulk DATA if initial CAPS was limited to 20", async () => {
    const { link, rx, state, frames } = await bluetooth(20);
    state.caps.max_write = 128; // The central negotiated a larger MTU after initial CAPS.
    await link.request(CMD.DATA, new Uint8Array(532));
    expect(frames.map((f) => f.type)).toEqual([CMD.CAPS, CMD.CAPS, CMD.DATA]);
    const dataStart = rx.writeValueWithResponse.mock.calls.length - 5;
    const dataLengths = rx.writeValueWithResponse.mock.calls
      .slice(dataStart)
      .map((c) => c[0].length);
    expect(dataLengths).toEqual([128, 128, 128, 128, 40]);
    await link.request(CMD.DATA, new Uint8Array(532));
    expect(frames.map((f) => f.type)).toEqual([
      CMD.CAPS, CMD.CAPS, CMD.DATA, CMD.DATA,
    ]);
    link.close();
  });
  it("serializes queued requests and dispatches CHANGED without consuming the ACK", async () => {
    vi.useFakeTimers();
    const { link, state, frames, reply } = await bluetooth();
    const changed = vi.fn();
    link.onChanged = changed;
    state.handle = (f) => {
      if (f.type === CMD.LIST) reply(f, { items: [] });
    };
    const first = link.request(CMD.STATUS),
      second = link.request(CMD.LIST);
    await vi.advanceTimersByTimeAsync(0);
    expect(frames.map((f) => f.type)).toEqual([CMD.CAPS, CMD.STATUS]);
    const f = frames[1]!;
    reply(
      { ...f, session: 0, seq: 0 },
      { generation: 2, mode: 3, phase: 0 },
      CMD.CHANGED,
    );
    expect(changed).toHaveBeenCalledTimes(1);
    expect(changed).toHaveBeenCalledWith(
      expect.objectContaining({ generation: 2, mode: 3, phase: 0 }),
    );
    reply(f, { mode: 3 });
    await expect(first).resolves.toMatchObject({ mode: 3 });
    await expect(second).resolves.toMatchObject({ items: [] });
    expect(frames[2]!.seq).toBe(f.seq + 1);
    link.close();
  });
  it("rejects wrong request_type and legacy string ERROR codes", async () => {
    const { link, state, reply } = await bluetooth();
    state.handle = (f) => reply(f, { request_type: CMD.DELETE });
    await expect(link.request(CMD.STATUS)).rejects.toThrow("request_type");
    state.handle = (f) =>
      reply(f, { code: "BUSY", next_block: null }, CMD.ERROR);
    await expect(link.request(CMD.STATUS)).rejects.toThrow("整数");
    state.handle = (f) => reply(f, { code: 1, next_block: null }, CMD.ERROR);
    await expect(link.request(CMD.STATUS)).rejects.toMatchObject({ code: 1 });
    link.close();
  });
  it("waits 30 seconds per COMMIT attempt and sends at most three identical frames", async () => {
    vi.useFakeTimers();
    const { link, state, frames } = await bluetooth();
    state.handle = () => {};
    const result = link
      .request(CMD.COMMIT, jsonBytes({ id: "test" }))
      .catch((e) => e);
    await vi.advanceTimersByTimeAsync(29999);
    expect(frames).toHaveLength(2);
    await vi.advanceTimersByTimeAsync(60002);
    expect(await result).toBeInstanceOf(TransportError);
    expect(frames).toHaveLength(4);
    expect(frames[1]).toEqual(frames[2]);
    expect(frames[2]).toEqual(frames[3]);
    link.close();
  });
  it("bounds a hanging GATT write and disconnects instead of leaving busy locked", async () => {
    vi.useFakeTimers();
    const { link, rx, gatt } = await bluetooth();
    rx.writeValueWithResponse.mockImplementation(() => new Promise(() => {}));
    const result = link.request(CMD.STATUS).catch((error: Error) => error);
    await vi.advanceTimersByTimeAsync(5001);
    expect(
      await Promise.race([result, Promise.resolve("still pending")]),
    ).toBeInstanceOf(Error);
    expect(gatt.connected).toBe(false);
    link.close();
  });
  it("releases a request when disconnected during a hanging write", async () => {
    const { link, rx, gatt } = await bluetooth();
    rx.writeValueWithResponse.mockImplementation(() => new Promise(() => {}));
    const result = link.request(CMD.STATUS).catch((error: Error) => error);
    gatt.disconnect();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(
      await Promise.race([result, Promise.resolve("still pending")]),
    ).toBeInstanceOf(Error);
    link.close();
  });
  it("does not lock busy after a locally invalid payload", async () => {
    const { link } = await bluetooth();
    await expect(link.request(CMD.BEGIN, new Uint8Array(1025))).rejects.toThrow(
      "过长",
    );
    await expect(link.request(CMD.STATUS)).resolves.toEqual({
      request_type: CMD.STATUS,
    });
    link.close();
  });
  it("retries identical bytes and ignores stale responses for other sequences", async () => {
    vi.useFakeTimers();
    const { link, state, frames, reply } = await bluetooth();
    let attempt = 0;
    state.handle = (f) => {
      if (++attempt === 2) {
        reply({ ...f, seq: f.seq - 1 }, { stale: true });
        reply(f, { mode: 0 });
        reply(f, { duplicate: true });
      }
    };
    const result = link.request(CMD.STATUS, new Uint8Array(), 50);
    await vi.advanceTimersByTimeAsync(51);
    await expect(result).resolves.toEqual({
      request_type: CMD.STATUS,
      mode: 0,
    });
    expect(frames[1]).toEqual(frames[2]);
    link.close();
  });
});
