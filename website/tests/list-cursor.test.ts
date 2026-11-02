import { describe, expect, it } from "vitest";
import { listEntries, type DeviceLink, type Entry } from "../src/lib/device-contract";
import { CMD } from "../src/lib/protocol";
import { readJson } from "../src/lib/wire";

function pagedLink(nextCursors: (number | null)[]) {
  const cursors: number[] = [];
  const entries: Entry[] = nextCursors.map((_, index) => ({
    id: `12345678-1234-5678-9abc-${String(index + 1).padStart(12, "0")}`,
    title: `曲目 ${index + 1}`,
    entry_state: 2,
    total_bytes: 64,
    file_crc: index + 1,
    capabilities: 1,
    next_block: 1,
    total_blocks: 1,
  }));
  const link: DeviceLink = {
    kind: "demo",
    name: "Opaque cursor fixture",
    identity: "list-cursor-fixture",
    closed: false,
    async request<T>(type: number, payload = new Uint8Array()): Promise<T> {
      expect(type).toBe(CMD.LIST);
      const request = readJson<{ generation: number; cursor: number; limit: number }>(payload);
      expect(request.limit).toBe(1);
      expect(request.generation).toBe(cursors.length === 0 ? 0 : 17);
      cursors.push(request.cursor);
      const index = cursors.length - 1;
      expect(index).toBeLessThan(nextCursors.length);
      return {
        request_type: CMD.LIST,
        generation: 17,
        next_cursor: nextCursors[index],
        items: [entries[index]],
      } as T;
    },
    close() {
      this.closed = true;
    },
  };
  return { link, cursors, entries };
}

describe("opaque LIST pagination cursors", () => {
  it("follows a valid 0 -> 42 -> 7 -> end sequence without assuming numeric order", async () => {
    const { link, cursors, entries } = pagedLink([42, 7, null]);
    await expect(listEntries(link)).resolves.toEqual(entries);
    expect(cursors).toEqual([0, 42, 7]);
  });

  it("rejects a return to initial cursor zero before issuing another LIST", async () => {
    const { link, cursors } = pagedLink([42, 0]);
    await expect(listEntries(link)).rejects.toThrow("游标");
    expect(cursors).toEqual([0, 42]);
  });

  it("rejects a 42 -> 7 -> 42 loop before repeating the previous page", async () => {
    const { link, cursors } = pagedLink([42, 7, 42]);
    await expect(listEntries(link)).rejects.toThrow("游标");
    expect(cursors).toEqual([0, 42, 7]);
  });

  it.each([-1, 0.5, 0x100000000])("rejects a non-u32 cursor %s", async (cursor) => {
    const { link, cursors } = pagedLink([cursor]);
    await expect(listEntries(link)).rejects.toThrow("游标");
    expect(cursors).toEqual([0]);
  });
});
