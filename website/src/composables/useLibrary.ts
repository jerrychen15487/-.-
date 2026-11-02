import { ref, shallowRef } from "vue";
import type { Score } from "../lib/pseq";

export type CatalogItem = {
  id: string;
  title: string;
  subtitle: string;
  level: string;
  tempo: number;
  duration: number;
  notes: number;
  bytes: number;
  crc: number;
  file: string;
  cover: string;
  capabilities: number;
  revision: number;
};

// A single session-only slot survives navigation; replacing or clearing it
// releases the previous import. Nothing is written to browser storage.
const imported = shallowRef<Score>();

export function useLibrary() {
  const items = ref<CatalogItem[]>([]);
  const catalogState = ref<"loading" | "ready" | "error">("loading");
  const catalogError = ref("");

  async function loadCatalog() {
    catalogState.value = "loading";
    catalogError.value = "";
    try {
      const response = await fetch(
        import.meta.env.BASE_URL + "scores/catalog.json",
      );
      if (!response.ok) throw Error("曲库加载失败，请重新加载");
      const result = await response.json();
      if (!Array.isArray(result)) throw Error("曲库目录格式错误，请重新加载");
      items.value = result;
      catalogState.value = "ready";
    } catch (error) {
      items.value = [];
      catalogError.value =
        error instanceof Error ? error.message : String(error);
      catalogState.value = "error";
    }
  }

  return {
    imported,
    rememberImported: (score: Score) => {
      imported.value = score;
    },
    clearImported: () => {
      imported.value = undefined;
    },
    items,
    catalogState,
    catalogError,
    loadCatalog,
  };
}
