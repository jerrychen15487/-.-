/** OFFLINE test oracle only. Defaults from shared FPGA plan §5, 2026-10-11.
 * Never imported by src/. Times below are calibrated milliseconds, not raw SPI arrival.
 */
export const ranges = [
  [1, 21],
  [22, 42],
  [43, 63],
  [64, 84],
  [85, 105],
  [106, 127],
] as const;
export function timing(error: number) {
  return Math.abs(error) <= 50 ? 100 : Math.abs(error) <= 100 ? 70 : 0;
}
export function hold(
  start: number,
  end: number,
  on: number | null,
  off: number | null,
) {
  if (on === null || off === null || !timing(on - start)) return 0;
  const fraction =
    Math.max(0, Math.min(end, off) - Math.max(start, on)) / (end - start);
  return Math.min(100 * fraction, timing(off - end));
}
export function dynamic(
  level: number,
  velocity: number,
  matched = true,
): number | null {
  if (!level) return null;
  const [lo, hi] = ranges[level - 1]!;
  return matched && velocity >= lo && velocity <= hi ? 100 : 0;
}
export function pedal(
  start: number,
  end: number,
  down: number | null,
  up: number | null,
) {
  if (down === null || up === null) return 0;
  const fraction =
    Math.max(0, Math.min(end, up) - Math.max(start, down)) / (end - start);
  return Math.min(timing(down - start), timing(up - end), 100 * fraction);
}
export function total(parts: (number | null)[]) {
  const weights = [50, 20, 20, 10];
  let sum = 0,
    weight = 0;
  parts.forEach((p, i) => {
    if (p !== null) {
      sum += p * weights[i]!;
      weight += weights[i]!;
    }
  });
  return weight ? Math.round(sum / weight) : null;
}
type Target = {
  id: number;
  ms: number;
  pitch: number;
  part: number;
  scored: boolean;
};
/** bit0 low, bit1 high, both common. Consume unselected matches as well. */
export function match(
  targets: Target[],
  events: { ms: number; pitch: number }[],
  part: number,
) {
  const used = new Set<number>();
  let combo = 0,
    maxCombo = 0,
    extra = 0;
  const output = events.map((e) => {
    const candidates = targets.filter(
      (t) =>
        !used.has(t.id) && t.pitch === e.pitch && Math.abs(t.ms - e.ms) <= 100,
    );
    const sorted = (list: Target[]) =>
      list.sort(
        (a, b) =>
          Math.abs(a.ms - e.ms) - Math.abs(b.ms - e.ms) ||
          a.ms - b.ms ||
          a.id - b.id,
      );
    const t =
      sorted(candidates.filter((t) => t.part & part))[0] ??
      sorted(candidates.filter((t) => !(t.part & part)))[0];
    if (!t) {
      extra++;
      combo = 0;
      return { id: null, score: null, combo };
    }
    used.add(t.id);
    const score = t.part & part && t.scored ? timing(e.ms - t.ms) : null;
    if (score !== null) {
      combo++;
      maxCombo = Math.max(maxCombo, combo);
    }
    return { id: t.id, score, combo };
  });
  // This helper tests matching streams without interleaved expired windows.
  // Miss/rollback ordering has separate explicit history vectors.
  return { output, extra, maxCombo };
}
export function rollback(
  safe: number[],
  pause: number,
  results: { id: number; start: number }[],
  history: { tick: number; correct: boolean; targetId: number | null }[],
) {
  const start = safe.filter((t) => t <= pause).at(-1) ?? 0;
  const keep = results.filter((r) => r.start < start).map((r) => r.id);
  const keptTargets = new Set(keep);
  let combo = 0,
    maxCombo = 0;
  // Hits and Misses belong to the target, even when their actual event/expiry
  // falls across the restart boundary. Only extra notes have no target.
  const retained = history.filter((e) =>
    e.targetId === null ? e.tick < start : keptTargets.has(e.targetId),
  );
  for (const e of retained) {
    combo = e.correct ? combo + 1 : 0;
    maxCombo = Math.max(maxCombo, combo);
  }
  return {
    start,
    keep,
    combo,
    maxCombo,
    history: retained,
  };
}
