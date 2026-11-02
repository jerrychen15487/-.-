import { crc32, uuid } from "./binary";
import { DYNAMICS, PPQ, RECORD_BYTES, SECTION, isId, validTitle } from "./protocol";

export type Note = {
  id: number;
  startTick: number;
  durationTicks: number;
  pitch: number;
  dynamic: number;
  part: number;
  flags: number;
  group: number;
};
export type Control = {
  tick: number;
  controller: number;
  value: number;
  flags: number;
};
export type Measure = {
  startTick: number;
  endTick: number;
  index: number;
  numerator: number;
  denominatorPow: number;
};
export type Page = {
  id: number;
  profile: number;
  notation: number;
  width: number;
  height: number;
  stride: number;
  pixels: Uint8Array;
};
export type Anchor = {
  startTick: number;
  pageId: number;
  measureIndex: number;
  x: number;
  y: number;
  width: number;
  height: number;
  notation: number;
};
export type Score = {
  id: string;
  revision: number;
  durationTicks: number;
  bpm: number;
  capabilities: number;
  notes: Note[];
  controls: Control[];
  measures: Measure[];
  pages: Page[];
  anchors: Anchor[];
  safeStarts: number[];
  notationPractice: number[];
  meta: Record<string, unknown>;
  bytes: Uint8Array;
  crc: number;
  sectionCount: number;
};
export const MAX_FILE_BYTES = 32 * 1024 * 1024;
function check(value: unknown, why: string): asserts value {
  if (!value) throw Error(`曲目包无效：${why}`);
}
const decoder = new TextDecoder("utf-8", { fatal: true });

/** All parts and all supplied pedal events participate. Releases at t precede new actions. */
export function computeSafeStarts(
  notes: Pick<Note, "startTick" | "durationTicks">[],
  measures: Pick<Measure, "startTick">[],
  controls: Control[],
  duration: number,
): number[] {
  const candidates = [
    ...new Set([
      0,
      ...notes.map((n) => n.startTick),
      ...measures.map((m) => m.startTick),
    ]),
  ]
    .filter((t) => t < duration)
    .sort((a, b) => a - b);
  const sorted = [...notes].sort((a, b) => a.startTick - b.startTick);
  const pedal = controls.filter((c) => c.controller === 64);
  let ni = 0,
    ci = 0,
    latestEnd = 0,
    down = false;
  return candidates.filter((t) => {
    while (ni < sorted.length && sorted[ni]!.startTick < t) {
      const n = sorted[ni++]!;
      latestEnd = Math.max(latestEnd, n.startTick + n.durationTicks);
    }
    while (ci < pedal.length && pedal[ci]!.tick < t)
      down = pedal[ci++]!.value >= 64;
    const releasedHere = pedal[ci]?.tick === t && pedal[ci]!.value < 64;
    return t === 0 || (latestEnd <= t && (!down || releasedHere));
  });
}

export function parseScore(input: Uint8Array): Score {
  check(
    input.length >= 64 && input.length <= MAX_FILE_BYTES,
    "文件大小超出 64 字节～32 MiB",
  );
  const bytes = input.slice(),
    v = new DataView(bytes.buffer);
  const u16 = (o: number) => v.getUint16(o, true),
    u32 = (o: number) => v.getUint32(o, true);
  const zero = (a: number, b: number) =>
    bytes.subarray(a, b).every((x) => x === 0);
  check(
    bytes[0] === 80 &&
      bytes[1] === 83 &&
      bytes[2] === 67 &&
      bytes[3] === 50 &&
      u16(4) === 2 &&
      u16(6) === 0,
    "仅支持 PSC2 2.0",
  );
  check(
    u32(8) === bytes.length && u16(38) === 64 && u32(40) === 64,
    "文件头长度不匹配",
  );
  check(
    u16(52) === PPQ && u16(54) >= 20 && u16(54) <= 300 && zero(56, 64),
    "PPQ、默认 BPM 或保留字段错误",
  );
  const id = uuid(bytes.subarray(12, 28));
  check(isId(id), "非法曲目身份：UUID 不能为全零");
  const count = u16(36),
    duration = u32(32),
    caps = u32(44);
  check(
    count > 0 && count <= 128 && 64 + count * 32 <= bytes.length,
    "分段目录越界",
  );
  check(duration > 0 && caps > 0 && !(caps & ~7), "时长或能力标志错误");
  type Section = {
    type: number;
    profile: number;
    start: number;
    end: number;
    count: number;
    size: number;
  };
  const sections: Section[] = [],
    keys = new Set<string>();
  for (let i = 0; i < count; i++) {
    const o = 64 + i * 32,
      type = u32(o),
      profile = u16(o + 4),
      flags = u16(o + 6);
    const start = u32(o + 8),
      length = u32(o + 12),
      n = u32(o + 16),
      size = u16(o + 20);
    check(
      !(flags & ~1) && u16(o + 22) === 0 && u32(o + 28) === 0,
      "目录保留字段错误",
    );
    check(
      start % 4 === 0 &&
        start >= 64 + count * 32 &&
        start + length <= bytes.length,
      "数据段越界或未对齐",
    );
    check(
      !sections.some((s) => start < s.end && start + length > s.start),
      "数据段重叠",
    );
    check(!keys.has(`${type}:${profile}`), "数据段重复");
    keys.add(`${type}:${profile}`);
    const known = Object.hasOwn(RECORD_BYTES, type);
    check(known || !(flags & 1), "未知必需数据段");
    if (known) {
      check(
        flags === 1 && size === RECORD_BYTES[type],
        "已知段标志或记录长度错误",
      );
      const visual =
        type === SECTION.PAGE ||
        type === SECTION.BITMAP ||
        type === SECTION.ANCHOR;
      check(profile === (visual ? 1 : 0), "不支持的 profile");
      check(size ? n * size === length : n === 1, "记录数量错误");
    }
    check(
      crc32(bytes.subarray(start, start + length)) === u32(o + 24),
      "数据段 CRC 不匹配",
    );
    sections.push({
      type,
      profile,
      start,
      end: start + length,
      count: n,
      size,
    });
  }
  check(
    new Set(sections.filter((s) => s.profile !== 0).map((s) => s.profile))
      .size <= 1,
    "每包至多一种非零 profile",
  );
  let end = 64 + count * 32;
  for (const s of [...sections].sort((a, b) => a.start - b.start)) {
    check(zero(end, s.start), "段间填充必须为零");
    end = s.end;
  }
  check(bytes.length % 4 === 0 && zero(end, bytes.length), "段尾填充错误");
  const get = (type: number) => sections.find((s) => s.type === type);
  const each = (type: number, fn: (o: number, i: number) => void) => {
    const s = get(type);
    if (s) for (let i = 0; i < s.count; i++) fn(s.start + i * s.size, i);
  };
  const metaSection = get(SECTION.META);
  check(
    metaSection && metaSection.end - metaSection.start <= 65536,
    "缺少或过大的 META",
  );
  let meta: Record<string, unknown>;
  try {
    meta = JSON.parse(
      decoder.decode(bytes.subarray(metaSection.start, metaSection.end)),
    );
  } catch {
    throw Error("曲目包无效：元数据不是合法 UTF-8 JSON");
  }
  check(
    meta &&
      typeof meta === "object" &&
      !Array.isArray(meta) &&
      validTitle(meta.title),
    "元数据标题错误",
  );
  check(
    [meta.source, meta.generator_version].every(
      (x) => typeof x === "string" && x.trim(),
    ),
    "元数据缺少 source 或 generator_version",
  );
  check(
    !(caps & 1) ||
      (get(SECTION.NOTE) && get(SECTION.MEASURE) && get(SECTION.SAFE_START)),
    "练习缺少 NOTE、MEASURE 或 SAFE_START",
  );
  const notes: Note[] = [],
    groups = new Map<number, number>(),
    pitchEnds = new Map<number, number>();
  each(SECTION.NOTE, (o, id) => {
    const start = u32(o),
      length = u32(o + 4),
      pitch = bytes[o + 8]!,
      dynamic = bytes[o + 9]!,
      part = bytes[o + 10]!,
      flags = bytes[o + 11]!,
      group = u32(o + 12);
    check(
      length > 0 &&
        start + length <= duration &&
        pitch <= 127 &&
        dynamic < DYNAMICS.length &&
        part >= 1 &&
        part <= 3 &&
        !(flags & ~7),
      "音符字段错误",
    );
    check(!(flags & 6) || flags & 1, "保持释放/力度评分要求起音评分");
    check(!(flags & 4) || dynamic > 0, "力度评分缺少参考等级");
    const prev = notes.at(-1);
    check(
      !prev ||
        start > prev.startTick ||
        (start === prev.startTick &&
          (pitch > prev.pitch ||
            (pitch === prev.pitch && group >= prev.group))),
      "音符排序错误",
    );
    check(
      (pitchEnds.get(pitch) ?? 0) <= start,
      "同音重叠或重复目标必须在制作端处理",
    );
    check(
      !groups.has(group) || groups.get(group) === start,
      "和弦分组起点不一致",
    );
    groups.set(group, start);
    pitchEnds.set(pitch, start + length);
    notes.push({
      id,
      startTick: start,
      durationTicks: length,
      pitch,
      dynamic,
      part,
      flags,
      group,
    });
  });
  check(
    notes.length === u32(48) && (!(caps & 1) || notes.length > 0),
    "音符总数错误",
  );
  const controls: Control[] = [],
    ccKeys = new Set<string>();
  let pedalDown: Control | undefined;
  each(SECTION.CC, (o) => {
    const tick = u32(o),
      controller = bytes[o + 5]!,
      value = bytes[o + 6]!,
      flags = bytes[o + 7]!;
    check(
      tick <= duration &&
        bytes[o + 4] === 0 &&
        controller <= 127 &&
        value <= 127 &&
        !(flags & ~1) &&
        (!flags || controller === 64),
      "CC 字段错误",
    );
    check(!controls.length || tick >= controls.at(-1)!.tick, "CC 排序错误");
    check(!ccKeys.has(`${tick}:${controller}`), "同 tick 同控制器重复");
    ccKeys.add(`${tick}:${controller}`);
    const c = { tick, controller, value, flags };
    if (controller === 64) {
      if (value >= 64) {
        if (!pedalDown) pedalDown = c;
        else check(pedalDown.flags === flags, "踏板保持期间评分标志冲突");
      } else if (pedalDown) {
        check(pedalDown.flags === flags, "踏板配对评分标志不一致");
        pedalDown = undefined;
      } else check(!flags, "踏板评分松开缺少踩下");
    }
    controls.push(c);
  });
  check(!pedalDown?.flags, "评分踏板缺少结束松开");
  const measures: Measure[] = [];
  each(SECTION.MEASURE, (o, index) => {
    const start = u32(o),
      stop = u32(o + 4),
      numerator = bytes[o + 12]!,
      denominatorPow = bytes[o + 13]!;
    check(
      u32(o + 8) === index &&
        start === (measures.at(-1)?.endTick ?? 0) &&
        start < stop &&
        stop <= duration &&
        numerator >= 1 &&
        numerator <= 32 &&
        denominatorPow <= 6 &&
        u16(o + 14) === 0,
      "小节顺序、范围或拍号错误",
    );
    const fullLength = (PPQ * 4 * numerator) / 2 ** denominatorPow;
    const edge = index === 0 || stop === duration;
    check(
      edge ? stop - start <= fullLength : stop - start === fullLength,
      "小节时长与拍号不一致：仅首尾允许不完整小节",
    );
    measures.push({
      startTick: start,
      endTick: stop,
      index,
      numerator,
      denominatorPow,
    });
  });
  check(
    !get(SECTION.MEASURE) || measures.at(-1)?.endTick === duration,
    "小节未连续覆盖曲目",
  );
  const pages: Page[] = [],
    pageMap = new Map<number, Page>(),
    bitmap = get(SECTION.BITMAP);
  each(SECTION.PAGE, (o) => {
    const id = u32(o),
      profile = u16(o + 4),
      notation = bytes[o + 6]!,
      width = u16(o + 8),
      height = u16(o + 10),
      stride = u16(o + 12),
      start = u32(o + 16),
      length = u32(o + 20);
    check(
      !pageMap.has(id) && profile === 1 && (notation === 1 || notation === 2),
      "PAGE ID、profile 或类型错误",
    );
    check(
      bytes[o + 7] === 1 &&
        width === 960 &&
        height === 480 &&
        stride === 120 &&
        u16(o + 14) === 0 &&
        length === 57600,
      "profile 1 谱面布局错误",
    );
    check(
      bitmap && start >= bitmap.start && start + length <= bitmap.end,
      "谱面像素越界",
    );
    const page = {
      id,
      profile,
      notation,
      width,
      height,
      stride,
      pixels: bytes.subarray(start, start + length),
    };
    pages.push(page);
    pageMap.set(id, page);
  });
  check(!(caps & 2) || pages.some((p) => p.notation === 1), "缺少五线谱资源");
  check(!(caps & 4) || pages.some((p) => p.notation === 2), "缺少简谱资源");
  const anchors: Anchor[] = [];
  each(SECTION.ANCHOR, (o) => {
    const startTick = u32(o),
      pageId = u32(o + 4),
      measureIndex = u32(o + 8),
      x = u16(o + 12),
      y = u16(o + 14),
      width = u16(o + 16),
      height = u16(o + 18),
      notation = bytes[o + 20]!;
    const p = pageMap.get(pageId),
      m = measures[measureIndex],
      prev = anchors.at(-1);
    check(
      p &&
        m &&
        notation === p.notation &&
        startTick === m.startTick &&
        width > 0 &&
        height > 0 &&
        x + width <= p.width &&
        y + height <= p.height &&
        zero(o + 21, o + 24),
      "ANCHOR 引用或矩形错误",
    );
    check(
      !prev ||
        startTick > prev.startTick ||
        (startTick === prev.startTick && notation > prev.notation),
      "ANCHOR 排序或重复错误",
    );
    anchors.push({
      startTick,
      pageId,
      measureIndex,
      x,
      y,
      width,
      height,
      notation,
    });
  });
  const notationPractice: number[] = [];
  for (const notation of [1, 2]) {
    const list = anchors.filter((a) => a.notation === notation);
    check(
      !list.length || list.length === measures.length,
      "ANCHOR 部分覆盖：必须覆盖每个展开小节",
    );
    if (list.length && caps & 1) notationPractice.push(notation);
  }
  const safeStarts: number[] = [];
  each(SECTION.SAFE_START, (o) => safeStarts.push(u32(o)));
  if (get(SECTION.SAFE_START)) {
    const expected = computeSafeStarts(notes, measures, controls, duration);
    check(
      safeStarts.length === expected.length &&
        safeStarts.every((t, i) => t === expected[i]),
      "SAFE_START 含不安全点或缺失安全点",
    );
  }
  return {
    id,
    revision: u32(28),
    durationTicks: duration,
    bpm: u16(54),
    capabilities: caps,
    notes,
    controls,
    measures,
    pages,
    anchors,
    safeStarts,
    notationPractice,
    meta,
    bytes,
    crc: crc32(bytes),
    sectionCount: count,
  };
}

export const tickToMs = (tick: number, bpm: number) =>
  (tick * 60000) / (PPQ * bpm);
