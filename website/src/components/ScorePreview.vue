<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, watch } from "vue";
import { formatTime } from "../lib/pseq";
import { tickToMs, type Score } from "../lib/psc2";
import { ScoreTimeline } from "../lib/timeline";
import { PPQ } from "../lib/protocol";
const props = defineProps<{ score: Score }>();
const tab = ref("五线谱"),
  pageIndex = ref(0),
  canvas = ref<HTMLCanvasElement>(),
  playing = ref(false),
  time = ref(0),
  manual = ref(false);
const timeline = computed(() => new ScoreTimeline(props.score));
const notation = computed(() => (tab.value === "五线谱" ? 1 : 2));
const available = computed(() => [
  ...(props.score.capabilities & 2 ? ["五线谱"] : []),
  ...(props.score.capabilities & 4 ? ["简谱"] : []),
  ...(props.score.capabilities & 1 ? ["钢琴块"] : []),
]);
const pages = computed(() =>
  props.score.pages.filter((p) => p.notation === notation.value),
);
const anchor = computed(() =>
  timeline.value.anchorAt(time.value, notation.value),
);
const measure = computed(() => timeline.value.measureAt(time.value));
const page = computed(() => pages.value[pageIndex.value]);
const canPlay = computed(
  () =>
    tab.value === "钢琴块" ||
    props.score.notationPractice.includes(notation.value),
);
const scoring = computed(() => [
  ["起音", props.score.notes.some((n) => n.flags & 1)],
  ["保持释放", props.score.notes.some((n) => n.flags & 2)],
  ["力度", props.score.notes.some((n) => n.flags & 4)],
  [
    "踏板",
    props.score.controls.some((c) => c.controller === 64 && c.flags & 1),
  ],
]);
function follow() {
  if (manual.value) return;
  const id = anchor.value?.pageId;
  if (id !== undefined) {
    const index = pages.value.findIndex((p) => p.id === id);
    if (index >= 0) pageIndex.value = index;
  }
}
function seek() {
  playing.value = false;
  manual.value = false;
  follow();
}
function turnPage(delta: number) {
  playing.value = false;
  manual.value = true;
  pageIndex.value = Math.max(
    0,
    Math.min(pages.value.length - 1, pageIndex.value + delta),
  );
}
async function draw() {
  await nextTick();
  const p = page.value,
    c = canvas.value;
  if (!p || !c) return;
  c.width = p.width;
  c.height = p.height;
  const ctx = c.getContext("2d")!,
    image = ctx.createImageData(p.width, p.height);
  for (let y = 0; y < p.height; y++)
    for (let x = 0; x < p.width; x++) {
      const black = p.pixels[y * p.stride + (x >> 3)]! & (128 >> (x & 7)),
        o = (y * p.width + x) * 4;
      image.data.set(black ? [31, 42, 40, 255] : [255, 255, 255, 255], o);
    }
  ctx.putImageData(image, 0, 0);
}
watch(
  () => props.score,
  () => {
    playing.value = false;
    time.value = 0;
    pageIndex.value = 0;
    manual.value = false;
    tab.value = available.value[0] ?? "钢琴块";
  },
  { immediate: true },
);
watch(tab, () => {
  playing.value = false;
  manual.value = false;
  pageIndex.value = 0;
  follow();
});
watch([anchor, manual], follow);
watch([page, canvas], draw, { flush: "post", immediate: true });
let raf = 0,
  last = 0;
function frame(t: number) {
  if (playing.value) {
    if (last)
      time.value = Math.min(
        props.score.durationTicks,
        time.value + ((t - last) * props.score.bpm * PPQ) / 60000,
      );
    if (time.value >= props.score.durationTicks) playing.value = false;
  }
  last = t;
  if (playing.value) raf = requestAnimationFrame(frame);
}
watch(playing, (active) => {
  cancelAnimationFrame(raf);
  last = 0;
  if (active) raf = requestAnimationFrame(frame);
});
onBeforeUnmount(() => cancelAnimationFrame(raf));
const keys = Array.from({ length: 88 }, (_, i) => ({
  pitch: i + 21,
  black: [1, 3, 6, 8, 10].includes((i + 21) % 12),
  x: 0,
  w: 0,
}));
let white = 0;
for (const k of keys) {
  if (k.black) {
    k.x = (white * 920) / 52 - 5.2;
    k.w = 10.4;
  } else {
    k.x = (white++ * 920) / 52;
    k.w = 920 / 52;
  }
}
const outsideKeyboard = computed(() =>
  props.score.notes.some((n) => n.pitch < 21 || n.pitch > 108),
);
const ahead = computed(() => (props.score.bpm * PPQ * 4) / 60);
const visibleNotes = computed(() =>
  timeline.value
    .visibleNotes(time.value, ahead.value)
    .filter((n) => n.pitch >= 21 && n.pitch <= 108),
);
const blocks = computed(() =>
  visibleNotes.value.map((n) => {
    const k = keys[n.pitch - 21]!;
    return {
      id: n.id,
      x: k.x,
      w: k.w,
      y: 350 - ((n.startTick - time.value) * 300) / ahead.value,
      h: Math.max(4, (n.durationTicks * 300) / ahead.value),
      color: n.part === 1 ? "#e9a255" : n.part === 2 ? "#218a7d" : "#8066be",
    };
  }),
);
function toggle() {
  if (time.value >= props.score.durationTicks) time.value = 0;
  manual.value = false;
  follow();
  playing.value = !playing.value;
}
</script>
<template>
  <div class="preview-tabs">
    <UButton
      v-for="name in available"
      :key="name"
      :variant="tab === name ? 'solid' : 'ghost'"
      :color="tab === name ? 'primary' : 'neutral'"
      @click="tab = name"
      >{{ name }}</UButton
    >
  </div>
  <template v-if="tab !== '钢琴块'"
    ><div class="sheet-container" style="position: relative">
      <canvas
        v-if="page"
        ref="canvas"
        :aria-label="tab + '第' + (pageIndex + 1) + '页'"
        role="img"
      />
      <div
        v-if="!manual && anchor && page?.id === anchor.pageId"
        class="measure-highlight"
        :style="{
          left: anchor.x / 9.6 + '%',
          top: anchor.y / 4.8 + '%',
          width: anchor.width / 9.6 + '%',
          height: anchor.height / 4.8 + '%',
        }"
      />
    </div>
    <div class="preview-controls">
      <UButton
        color="neutral"
        variant="outline"
        :disabled="pageIndex === 0"
        @click="turnPage(-1)"
        >上一页</UButton
      ><span>{{ pageIndex + 1 }} / {{ pages.length }} 页</span
      ><UButton
        color="neutral"
        variant="outline"
        :disabled="pageIndex >= pages.length - 1"
        @click="turnPage(1)"
        >下一页</UButton
      >
    </div></template
  >
  <template v-else
    ><p v-if="outsideKeyboard" class="preview-note">
      预览显示 88 键范围，范围外音符仍保留在文件中。
    </p>
    <div class="roll-container">
      <svg viewBox="0 0 920 412" role="img" aria-label="无声钢琴块预览">
        <defs>
          <clipPath id="roll-clip"><rect width="920" height="350" /></clipPath>
        </defs>
        <rect width="920" height="412" fill="#f2f7f5" />
        <g v-for="k in keys.filter((k) => !k.black)" :key="k.pitch">
          <line :x1="k.x" y1="0" :x2="k.x" y2="350" stroke="#dfebe6" />
        </g>
        <g clip-path="url(#roll-clip)">
          <rect
            v-for="b in blocks"
            :key="b.id"
            :x="b.x + 1"
            :y="b.y - b.h"
            :width="b.w - 2"
            :height="b.h"
            :fill="b.color"
            rx="3"
          />
        </g>
        <line
          x1="0"
          y1="350"
          x2="920"
          y2="350"
          stroke="#218a7d"
          stroke-width="3"
        />
        <rect
          v-for="k in keys.filter((k) => !k.black)"
          :key="k.pitch"
          :x="k.x"
          y="354"
          :width="k.w - 1"
          height="57"
          fill="white"
          stroke="#b9cbc5"
        />
        <rect
          v-for="k in keys.filter((k) => k.black)"
          :key="k.pitch"
          :x="k.x"
          y="354"
          :width="k.w"
          height="34"
          fill="#253d38"
        />
      </svg>
    </div>
    <p class="preview-note">
      绿色：高音部 · 橙色：低音部 · 紫色：共同音
    </p></template
  >
  <div class="preview-controls">
    <UButton
      :disabled="!canPlay"
      :icon="playing ? 'i-lucide-pause' : 'i-lucide-play'"
      @click="toggle"
      >{{ playing ? "暂停" : "播放" }}</UButton
    >
    <span
      >{{ formatTime(tickToMs(time, score.bpm)) }} /
      {{ formatTime(tickToMs(score.durationTicks, score.bpm)) }}</span
    >
    <span class="muted">♩ = {{ score.bpm }} · 无声预览</span>
    <span v-if="measure"
      >第 {{ measure.index + 1 }} / {{ score.measures.length }} 小节</span
    >
  </div>
  <input
    v-model.number="time"
    type="range"
    :max="score.durationTicks"
    min="0"
    step="1"
    class="timeline"
    aria-label="预览进度"
    @input="seek"
  />
  <p v-if="!canPlay" class="preview-note">
    此谱面没有完整小节锚点，仅支持手动阅读。
  </p>
  <p v-if="manual && canPlay" class="preview-note">
    手动阅读中；播放位置保留，点击播放后返回对应小节。
  </p>
  <p class="preview-note">
    {{
      scoring
        .map(
          ([name, available]) => `${name}：${available ? "有参考" : "不计分"}`,
        )
        .join(" · ")
    }}<span v-if="score.controls.some((c) => c.controller === 64)">
      · 参考踏板：{{ timeline.pedalAt(time) ? "踩下" : "松开" }}</span
    >
  </p>
  <p class="preview-note">
    高音部在上、低音部在下；简谱括号内为原谱指法。渐变力度、断奏、延长号等没有明确目标的项目不评分。
  </p>
  <p class="preview-note">
    来源：{{ score.meta.source }}。默认 BPM 取自曲目包，预览采用全曲固定速度。
  </p>
</template>
<style scoped>
.measure-highlight {
  position: absolute;
  pointer-events: none;
  border: 2px solid #218a7d;
  background: #218a7d18;
  border-radius: 4px;
}
.sheet-container {
  padding: 0;
  overflow: hidden;
}
.preview-controls {
  flex-wrap: wrap;
}
.preview-note {
  overflow-wrap: anywhere;
}
</style>
