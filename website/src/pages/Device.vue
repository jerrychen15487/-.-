<script setup lang="ts">
import { reactive, ref } from "vue";
import { useDevice } from "../composables/useDevice";
import { formatBytes } from "../lib/pseq";
import { BLOCK_BYTES, MODE_NAMES } from "../lib/protocol";
import type { Entry } from "../lib/device";
const d = reactive(useDevice()),
  deleting = ref<Entry>(),
  confirm = ref(false);
const supported =
  typeof navigator !== "undefined" &&
  !!navigator.bluetooth &&
  window.isSecureContext;
const action = ref<"delete" | "redownload">("delete");
</script>
<template>
  <div class="page-intro">
    <h1>我的设备</h1>
  </div>
  <div class="device-grid">
    <UCard
      ><template #header
        ><div class="flex items-center gap-3">
          <UIcon name="i-lucide-bluetooth" class="size-6 text-teal-600" />
          <h2>蓝牙连接</h2>
          <UBadge color="warning" variant="soft" class="ml-auto"
            >待硬件联调</UBadge
          >
        </div></template
      >
      <p class="body-copy">Windows / Android Chrome，需配套 BLE 固件。</p>
      <UAlert
        v-if="!supported"
        title="当前环境不支持网页蓝牙"
        description="请使用 HTTPS 下的 Windows / Android Chrome。"
        color="warning"
        variant="soft"
        class="mt-4"
      />
      <div class="mt-6 flex flex-wrap gap-3">
        <UButton
          icon="i-lucide-bluetooth"
          :disabled="!supported || d.busy"
          :loading="d.busy && !d.link"
          @click="d.connect(false)"
          >连接真实设备</UButton
        ><UButton
          v-if="d.link"
          color="neutral"
          variant="outline"
          :disabled="d.busy"
          @click="d.disconnect"
          >断开连接</UButton
        >
      </div></UCard
    >
    <UCard class="demo-card"
      ><template #header
        ><div class="flex items-center gap-3">
          <UIcon name="i-lucide-flask-conical" class="size-6 text-amber-600" />
          <h2>演示设备</h2>
        </div></template
      >
      <p class="body-copy">仅浏览器内存，刷新清空，不写入硬件。</p>
      <UButton
        class="mt-6"
        color="neutral"
        variant="outline"
        icon="i-lucide-monitor-play"
        :disabled="d.busy"
        @click="d.connect(true)"
        >连接演示设备</UButton
      ></UCard
    >
  </div>
  <section class="mt-8">
    <div class="section-title">
      <div>
        <h2>设备本地曲库</h2>
        <p class="muted mt-2">
          {{ d.link?.name || "连接后查看已保存曲目" }}
        </p>
      </div>
      <UButton
        icon="i-lucide-refresh-cw"
        color="neutral"
        variant="outline"
        :disabled="!d.link || d.busy"
        @click="d.refresh"
        >刷新目录</UButton
      >
    </div>
    <div v-if="d.link && d.status" class="device-summary">
      <div>
        <span>当前状态</span><strong>{{ MODE_NAMES[d.status.mode] }}</strong>
      </div>
      <div>
        <span>可用空间</span
        ><strong>{{ formatBytes(d.status.free_bytes) }}</strong>
      </div>
      <div>
        <span>已保存曲目</span
        ><strong>{{
          d.directory === "known"
            ? d.entries.filter((e) => e.entry_state === 2).length + " 首"
            : "待查询"
        }}</strong>
      </div>
      <UButton
        v-if="d.link.kind === 'demo'"
        color="neutral"
        variant="outline"
        @click="d.toggleDemoState"
        >{{
          d.status.mode !== 0 ? "演示：返回管理状态" : "演示：切换演奏状态"
        }}</UButton
      >
    </div>
    <div v-if="d.link?.kind === 'demo'" class="flex flex-wrap gap-3 my-4">
      <UButton variant="outline" color="neutral" @click="d.restartDemo"
        >演示：设备重启并断连（保留内存曲库）</UButton
      >
    </div>
    <UButton
      v-if="d.status?.active_id && !d.busy"
      class="my-4"
      @click="d.pauseActive"
      >暂停设备当前下载</UButton
    >
    <div
      v-if="d.directory !== 'known' || !d.entries.length"
      class="empty-state"
    >
      <UIcon name="i-lucide-folder-open" class="size-10" />
      <h3>
        {{
          !d.link
            ? "尚未连接"
            : d.directory === "loading"
              ? "正在读取目录"
              : d.directory === "unknown"
                ? "目录未知，请刷新重试"
                : "已确认曲库为空"
        }}
      </h3>
      <UButton v-if="d.directory === 'known'" to="/" variant="soft"
        >浏览曲库</UButton
      >
    </div>
    <div v-else class="device-list">
      <div v-for="e in d.entries" :key="e.id" class="device-row">
        <div class="file-icon"><UIcon name="i-lucide-file-music" /></div>
        <div>
          <strong>{{ e.title }}</strong>
          <p class="uuid-label">{{ e.id }}</p>
          <p>
            {{ e.entry_state === 2 ? "完整 · 可用" : "未完成" }} ·
            {{
              formatBytes(Math.min(e.next_block * BLOCK_BYTES, e.total_bytes))
            }} /
            {{ formatBytes(e.total_bytes) }} · {{ e.next_block }} /
            {{ e.total_blocks }} 块 ·
            {{
              [
                e.capabilities & 2 ? "五线谱" : "",
                e.capabilities & 4 ? "简谱" : "",
                e.capabilities & 1 ? "钢琴块" : "",
              ]
                .filter(Boolean)
                .join(" / ")
            }}
          </p>
        </div>
        <div class="flex flex-wrap gap-2">
          <UButton
            v-if="e.entry_state === 1"
            :disabled="d.busy || d.status?.mode !== 0"
            @click="d.resume(e)"
            >续传</UButton
          >
          <UButton
            v-else
            variant="soft"
            :disabled="d.busy || d.status?.mode !== 0"
            @click="
              deleting = e;
              action = 'redownload';
              confirm = true;
            "
            >重新下载</UButton
          >
          <UButton
            color="error"
            variant="ghost"
            icon="i-lucide-trash-2"
            :disabled="d.busy || d.status?.mode !== 0"
            :aria-label="'删除' + e.title"
            @click="
              deleting = e;
              action = 'delete';
              confirm = true;
            "
            >删除</UButton
          >
          <UButton
            v-if="d.link?.kind === 'demo'"
            variant="ghost"
            color="neutral"
            :disabled="d.status?.mode !== 0"
            @click="d.demoLocalDelete(e)"
            >演示本地删除</UButton
          >
        </div>
      </div>
    </div>
  </section>
  <UModal
    v-model:open="confirm"
    :title="action === 'delete' ? '删除设备曲目？' : '重新下载曲目？'"
    :description="
      action === 'delete'
        ? '删除所选 UUID 的完整内容或全部未完成进度。'
        : '先删除设备上的完整曲目，再使用原文件重新下载；旧内容不保留。'
    "
    ><template #footer
      ><UButton color="neutral" variant="outline" @click="confirm = false"
        >保留曲目</UButton
      ><UButton
        color="error"
        :disabled="d.busy"
        @click="
          deleting &&
            (action === 'delete' ? d.remove(deleting) : d.redownload(deleting));
          confirm = false;
        "
        >{{ action === "delete" ? "确认删除" : "确认重新下载" }}</UButton
      ></template
    ></UModal
  >
</template>

<style scoped>
.uuid-label {
  overflow-wrap: anywhere;
  font-size: 11px;
}
.device-row > div {
  min-width: 0;
}
@media (max-width: 640px) {
  .device-row {
    flex-wrap: wrap;
  }
  .device-row > div:nth-child(2) {
    flex: 1;
  }
}
</style>
