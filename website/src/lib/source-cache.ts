import type { Score } from "./pseq";
import type { Entry } from "./device-contract";

export type SourceFingerprint = Pick<Entry, "id" | "total_bytes" | "file_crc">;
export const fingerprint = (score: Score): SourceFingerprint => ({
  id: score.id,
  total_bytes: score.bytes.length,
  file_crc: score.crc,
});
const key = (source: SourceFingerprint) =>
  `${source.id}:${source.total_bytes}:${source.file_crc}`;

/** Session-only LRU, budgeted by file bytes. Evicted imports can be reselected. */
export class ScoreSourceCache {
  private readonly files = new Map<string, Score>();
  private bytes = 0;

  constructor(private readonly budget = 64 * 1024 * 1024) {}

  get(source: SourceFingerprint): Score | undefined {
    const id = key(source), score = this.files.get(id);
    if (score) {
      this.files.delete(id);
      this.files.set(id, score);
    }
    return score;
  }

  remember(score: Score): void {
    if (score.bytes.length > this.budget) return;
    this.delete(fingerprint(score));
    while (this.bytes + score.bytes.length > this.budget) {
      const oldest = this.files.values().next().value!;
      this.delete(fingerprint(oldest));
    }
    this.files.set(key(fingerprint(score)), score);
    this.bytes += score.bytes.length;
  }

  delete(source: SourceFingerprint): void {
    const id = key(source), score = this.files.get(id);
    if (score) {
      this.bytes -= score.bytes.length;
      this.files.delete(id);
    }
  }
}
