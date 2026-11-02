import type { Score, Note, Anchor } from "./psc2";

export function upperBound<T>(
  items: T[],
  value: number,
  key: (item: T) => number,
): number {
  let lo = 0,
    hi = items.length;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if (key(items[mid]!) <= value) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}
/** Per-pitch non-overlapping intervals allow logarithmic seeking, even through long holds. */
export class ScoreTimeline {
  private pitches: Note[][] = Array.from({ length: 128 }, () => []);
  private anchors = new Map<number, Anchor[]>();
  private pedal: Score["controls"];
  constructor(readonly score: Score) {
    for (const n of score.notes) this.pitches[n.pitch]!.push(n);
    for (const a of score.anchors) {
      let list = this.anchors.get(a.notation);
      if (!list) {
        list = [];
        this.anchors.set(a.notation, list);
      }
      list.push(a);
    }
    this.pedal = score.controls.filter((c) => c.controller === 64);
  }
  measureAt(tick: number) {
    return this.score.measures[
      Math.max(0, upperBound(this.score.measures, tick, (m) => m.startTick) - 1)
    ];
  }
  anchorAt(tick: number, notation: number) {
    const list = this.anchors.get(notation) ?? [];
    return list[upperBound(list, tick, (a) => a.startTick) - 1];
  }
  pedalAt(tick: number) {
    return (
      (this.pedal[upperBound(this.pedal, tick, (c) => c.tick) - 1]?.value ??
        0) >= 64
    );
  }
  visibleNotes(tick: number, ahead: number): Note[] {
    const result: Note[] = [];
    for (const list of this.pitches) {
      let i = Math.max(0, upperBound(list, tick, (n) => n.startTick) - 1);
      for (; i < list.length && list[i]!.startTick <= tick + ahead; i++) {
        const n = list[i]!;
        if (n.startTick + n.durationTicks >= tick) result.push(n);
      }
    }
    return result.sort(
      (a, b) => a.startTick - b.startTick || a.pitch - b.pitch,
    );
  }
}
