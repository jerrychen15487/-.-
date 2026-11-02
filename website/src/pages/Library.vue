<script setup lang="ts">
import { computed, onMounted, reactive, ref, shallowRef } from "vue";
import {
  parseScore,
  formatBytes,
  formatTime,
  MAX_FILE_BYTES,
  type Score,
} from "../lib/pseq";
import { useDevice } from "../composables/useDevice";
import { useLibrary, type CatalogItem } from "../composables/useLibrary";
import ScorePreview from "../components/ScorePreview.vue";
const {
  imported,
  rememberImported,
  clearImported,
  items,
  catalogState,
  catalogError,
  loadCatalog,
} = useLibrary();
const query = ref(""),
  mode = ref("全部格式"),
  level = ref("全部难度"),
  error = ref(""),
  opening = ref(""),
  modal = ref(false),
  replaceConfirm = ref(false),
  selected = shallowRef<Score>(),
  input = ref<HTMLInputElement>(),
  d = reactive(useDevice());
const filtered = computed(() =>
  items.value.filter(
    (i) =>
      (i.title + i.subtitle)
        .toLowerCase()
        .includes(query.value.toLowerCase()) &&
      (level.value === "全部难度" || i.level === level.value) &&
      (mode.value === "全部格式" ||
        !!(
          i.capabilities & ({ 五线谱: 2, 简谱: 4, 钢琴块: 1 }[mode.value] || 0)
        )),
  ),
);
const base = import.meta.env.BASE_URL;
let selection = 0;
onMounted(loadCatalog);
async function openItem(item: CatalogItem) {
  const request = ++selection;
  opening.value = item.id;
  error.value = "";
  try {
    const r = await fetch(base + item.file);
    if (!r.ok) throw Error("曲目文件无法加载");
    const s = parseScore(new Uint8Array(await r.arrayBuffer()));
    if (
      s.crc !== item.crc ||
      s.id !== item.id ||
      s.revision !== item.revision ||
      s.bytes.length !== item.bytes
    )
      throw Error("曲目与目录校验不匹配");
    if (request !== selection) return;
    selected.value = s;
    modal.value = true;
  } catch (e) {
    if (request === selection) error.value = (e as Error).message;
  } finally {
    if (request === selection) opening.value = "";
  }
}
async function importFile(event: Event) {
  const request = ++selection;
  opening.value = "";
  error.value = "";
  const el = event.target as HTMLInputElement;
  const file = el.files?.[0];
  try {
    if (!file) return;
    if (!file.name.toLowerCase().endsWith(".pseq"))
      throw Error("请选择规定格式的 .pseq 文件");
    if (file.size > MAX_FILE_BYTES) throw Error("文件超过 32 MiB 上限");
    const score = parseScore(new Uint8Array(await file.arrayBuffer()));
    if (request !== selection) return;
    rememberImported(score);
    selected.value = score;
    modal.value = true;
  } catch (e) {
    if (request === selection) error.value = (e as Error).message;
  } finally {
    el.value = "";
  }
}
function openImported() {
  if (!imported.value) return;
  selection++;
  opening.value = "";
  error.value = "";
  selected.value = imported.value;
  modal.value = true;
}
function removeImported() {
  if (selected.value === imported.value) {
    selected.value = undefined;
    modal.value = false;
  }
  clearImported();
}
function saveFile() {
  if (!selected.value) return;
  const url = URL.createObjectURL(new Blob([selected.value.bytes.slice()]));
  const a = document.createElement("a");
  a.href = url;
  a.download = selected.value.id + ".pseq";
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
</script>
<template>
  <div class="section-title">
    <div>
      <h1>曲库</h1>
    </div>
    <UButton
      icon="i-lucide-upload"
      color="neutral"
      variant="outline"
      @click="input?.click()"
      >导入曲目包</UButton
    ><input
      ref="input"
      type="file"
      accept=".pseq"
      class="hidden"
      aria-label="导入本地曲目包"
      @change="importFile"
    />
  </div>
  <UCard v-if="imported" class="mb-5">
    <div class="flex flex-wrap items-center justify-between gap-3">
      <div class="min-w-0">
        <p class="font-medium break-words">
          已导入：{{ imported.meta.title }}
        </p>
        <p class="text-sm text-muted">
          {{ formatBytes(imported.bytes.length) }} ·
          本次打开网页期间保留一首，刷新后清空
        </p>
      </div>
      <div class="flex flex-wrap gap-2">
        <UButton variant="soft" @click="openImported"
          >打开已导入曲目</UButton
        >
        <UButton variant="ghost" color="neutral" @click="removeImported"
          >移除已导入项</UButton
        >
      </div>
    </div>
  </UCard>
  <div class="filter-bar">
    <UInput
      v-model="query"
      icon="i-lucide-search"
      placeholder="搜索曲目或练习内容…"
      aria-label="搜索曲目"
      class="search-field"
      size="lg"
    /><USelect
      v-model="mode"
      :items="['全部格式', '五线谱', '简谱', '钢琴块']"
      aria-label="曲谱格式"
      size="lg"
    /><USelect
      v-model="level"
      :items="['全部难度', '入门', '基础']"
      aria-label="练习难度"
      size="lg"
    />
  </div>
  <div class="collection-meta">
    <span>{{
      catalogState === "ready"
        ? `${filtered.length} 首曲目`
        : catalogState === "loading"
          ? "曲库加载中"
          : "曲库暂不可用"
    }}</span
    ><span>公开版权完整作品 · PSC2</span>
  </div>
  <UAlert v-if="error" color="error" :title="error" class="mb-5" />
  <div v-if="catalogState === 'loading'" class="empty-state">
    正在打开曲库…
  </div>
  <div
    v-else-if="catalogState === 'error'"
    class="empty-state"
    role="alert"
  >
    <UIcon name="i-lucide-circle-alert" class="size-10" />
    <h3>曲库加载失败</h3>
    <p>{{ catalogError }}</p>
    <UButton variant="soft" @click="loadCatalog">重新加载</UButton>
  </div>
  <div v-else-if="!items.length" class="empty-state">
    <UIcon name="i-lucide-library" class="size-10" />
    <h3>曲库暂时没有曲目</h3>
    <UButton variant="soft" @click="loadCatalog">重新加载</UButton>
  </div>
  <div v-else-if="!filtered.length" class="empty-state">
    <UIcon name="i-lucide-search" class="size-10" />
    <h3>暂时没有匹配的曲目</h3>
    <p>试试其他关键词。</p>
    <UButton
      variant="soft"
      @click="
        query = '';
        mode = '全部格式';
        level = '全部难度';
      "
      >重置筛选</UButton
    >
  </div>
  <div v-else class="score-grid">
    <article
      v-for="(item, index) in filtered"
      :key="item.id"
      class="score-card"
    >
      <button
        class="score-cover"
        :class="'cover-' + (index % 3)"
        :aria-label="'预览' + item.title"
        @click="openItem(item)"
      >
        <span class="cover-number">{{
          String(index + 1).padStart(2, "0")
        }}</span
        ><img :src="base + item.cover" :alt="item.title + '五线谱节选'" /><span
          class="cover-preview"
          ><UIcon name="i-lucide-eye" /> 预览曲谱</span
        >
      </button>
      <div class="score-info">
        <div class="score-heading">
          <h3>{{ item.title }}</h3>
          <UBadge color="neutral" variant="soft">{{ item.level }}</UBadge>
        </div>

        <div class="score-metrics">
          <span
            ><UIcon name="i-lucide-clock-3" />{{
              formatTime(item.duration)
            }}</span
          ><span>♩ = {{ item.tempo }}</span
          ><span>{{ item.notes }} 个音符</span>
        </div>
        <div class="score-formats">
          <span v-if="item.capabilities & 2">五线谱</span
          ><span v-if="item.capabilities & 4">简谱</span
          ><span v-if="item.capabilities & 1">钢琴块</span>
        </div>
        <div class="score-bottom">
          <span>{{ formatBytes(item.bytes) }}</span
          ><UButton
            variant="soft"
            trailing-icon="i-lucide-arrow-up-right"
            :loading="opening === item.id"
            @click="openItem(item)"
            >打开曲谱</UButton
          >
        </div>
      </div>
    </article>
  </div>
  <UModal
    v-model:open="modal"
    :title="String(selected?.meta.title || '曲目预览')"
    description="预览、保存文件或发送到设备。"
    :ui="{ content: 'sm:max-w-5xl' }"
    ><template #body
      ><ScorePreview v-if="selected" :score="selected" /></template
    ><template #footer
      ><div class="preview-footer">
        <span
          >{{ selected ? formatBytes(selected.bytes.length) : "" }} ·
          包校验通过</span
        >
        <div class="flex gap-2">
          <UButton
            color="neutral"
            variant="outline"
            icon="i-lucide-download"
            @click="saveFile"
            >保存文件</UButton
          ><UButton
            v-if="d.link"
            icon="i-lucide-send"
            :loading="d.busy"
            :disabled="d.busy || d.status?.mode !== 0"
            @click="
              if (
                selected &&
                d.entries.some(
                  (e) => e.id === selected!.id && e.entry_state === 2,
                )
              )
                replaceConfirm = true;
              else {
                selected && d.upload(selected);
                modal = false;
              }
            "
            >{{
              d.entries.some(
                (e) => e.id === selected?.id && e.entry_state === 2,
              )
                ? "重新下载"
                : d.link.kind === "demo"
                  ? "发送到演示设备"
                  : "发送到设备"
            }}</UButton
          ><UButton
            v-else
            to="/device"
            icon="i-lucide-bluetooth"
            @click="modal = false"
            >先连接设备</UButton
          >
        </div>
      </div></template
    ></UModal
  >
  <UModal
    v-model:open="replaceConfirm"
    title="重新下载此曲目？"
    description="先删除设备上的同 UUID 完整曲目，再下载当前曲目包。删除后旧内容不保留。"
  >
    <template #footer
      ><UButton
        variant="outline"
        color="neutral"
        @click="replaceConfirm = false"
        >保留现有曲目</UButton
      ><UButton
        color="warning"
        @click="
          selected && d.upload(selected, true);
          replaceConfirm = false;
          modal = false;
        "
        >确认重新下载</UButton
      ></template
    >
  </UModal>
</template>
