import { beforeEach, afterEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { parseScore } from "../src/lib/pseq";
import { useLibrary } from "../src/composables/useLibrary";

const score = parseScore(
  new Uint8Array(readFileSync("tests/fixtures/packages/engineering.pseq")),
);
const catalog = JSON.parse(readFileSync("public/scores/catalog.json", "utf8"));

beforeEach(() => useLibrary().clearImported());
afterEach(() => vi.unstubAllGlobals());

describe("library state across navigation and loading failures", () => {
  it("keeps one imported score available to a later page instance", () => {
    const first = useLibrary();
    first.rememberImported(score);
    const afterNavigation = useLibrary();
    expect(afterNavigation.imported.value).toBe(score);
  });

  it("replaces and explicitly removes the single imported score", () => {
    const first = useLibrary();
    const next = useLibrary();
    const replacement = {
      ...score,
      id: "00000000-0000-0000-0000-000000000002",
    };
    first.rememberImported(score);
    next.rememberImported(replacement);
    expect(first.imported.value).toBe(replacement);
    first.clearImported();
    expect(next.imported.value).toBeUndefined();
  });

  it("reports a failed catalog separately and recovers on retry", async () => {
    const fetch = vi
      .fn()
      .mockResolvedValueOnce({ ok: false })
      .mockResolvedValueOnce({ ok: true, json: async () => catalog });
    vi.stubGlobal("fetch", fetch);
    const library = useLibrary();
    await library.loadCatalog();
    expect(library.catalogState.value).toBe("error");
    expect(library.catalogError.value).toContain("加载失败");
    await library.loadCatalog();
    expect(library.catalogState.value).toBe("ready");
    expect(library.catalogError.value).toBe("");
    expect(library.items.value).toEqual(catalog);
    expect(fetch).toHaveBeenCalledTimes(2);
  });

  it("distinguishes a successfully loaded empty catalog from an error", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({ ok: true, json: async () => [] }),
    );
    const library = useLibrary();
    await library.loadCatalog();
    expect(library.catalogState.value).toBe("ready");
    expect(library.items.value).toEqual([]);
    expect(library.catalogError.value).toBe("");
  });

  it("leaves the imported score accessible when the public catalog cannot load", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("网络不可用")));
    const library = useLibrary();
    library.rememberImported(score);
    await library.loadCatalog();
    expect(library.catalogState.value).toBe("error");
    expect(library.catalogError.value).toBe("网络不可用");
    expect(library.imported.value).toBe(score);
  });
});
