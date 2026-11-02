import { describe, it, expect } from "vitest";
import { CMD, ERR, PPQ, RECORD_BYTES } from "../src/lib/protocol";
import { crc32, uuidBytes } from "../src/lib/pseq";
import vectors from './fixtures/v2-golden.json';
import {validateCaps,validateStatus,validateEntry,validateChanged} from '../src/lib/device-contract';
import {FrameDecoder,jsonBytes,readJson} from '../src/lib/wire';
describe("published v2 golden vectors (independent fixed bytes)", () => {
  it('validates frozen JSON and full UUID/DATA bytes for cross-language integration',()=>{
    expect(validateCaps(vectors.caps).profiles).toEqual([1]);
    expect(validateStatus(vectors.status).free_bytes).toBe(9007199254740993n);
    expect(validateEntry(vectors.list.items[0]!).next_block).toBe(1);
    expect(validateChanged(vectors.changed).mode).toBe(3);
    const bytes=Uint8Array.from(vectors.data_payload_hex.match(/../g)!,x=>parseInt(x,16));
    expect([...bytes.slice(0,16)]).toEqual([...uuidBytes(vectors.data_expected.id)]);
    expect(new DataView(bytes.buffer).getUint32(16,true)).toBe(3);
    expect([...bytes.slice(20)]).toEqual([80,83,67,50]);
    expect(new FrameDecoder().push(Uint8Array.from(vectors.caps_frame_hex.match(/../g)!,x=>parseInt(x,16)))[0]!.type).toBe(CMD.CAPS);
    for(const value of [vectors.begin_ack,vectors.data_ack,vectors.pause_ack,vectors.commit_ack,vectors.delete_ack,vectors.error,vectors.changed])expect(readJson(jsonBytes(value))).toEqual(value);
  });
  it("matches the shared CAPS frame CRC and NOTE layout", () => {
    const b = Uint8Array.from("a5 5a 02 01 01 00 00 00 01 00 00 00 00 00 00 00 1e 28 4c ba".split(" "), x => parseInt(x,16));
    expect(crc32(b.subarray(2,16))).toBe(0xba4c281e);
    const note=Uint8Array.from("c0 03 00 00 e0 01 00 00 3c 04 02 07 07 00 00 00".split(" "),x=>parseInt(x,16));
    const v=new DataView(note.buffer);
    expect([v.getUint32(0,true),v.getUint32(4,true),...note.slice(8,12),v.getUint32(12,true)]).toEqual([960,480,60,4,2,7,7]);
    expect(PPQ).toBe(960); expect(RECORD_BYTES[4]).toBe(16);
  });
  it("preserves UUID byte order and assigned command/error numbers", () => {
    expect([...uuidBytes("00112233-4455-6677-8899-aabbccddeeff")]).toEqual([0,17,34,51,68,85,102,119,136,153,170,187,204,221,238,255]);
    expect([CMD.PAUSE,CMD.CHANGED,ERR.CONTENT_MISMATCH,ERR.ALREADY_STORED]).toEqual([19,144,9,12]);
  });
});
