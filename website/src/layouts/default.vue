<script setup lang="ts">
import { computed, reactive, ref } from "vue";
import { useRoute } from "vue-router";
import { useDevice } from "../composables/useDevice";
import { formatBytes } from "../lib/binary";
import { BLOCK_BYTES } from "../lib/protocol";
const open = ref(false),
  route = useRoute(),
  d = reactive(useDevice());
const title = computed(() =>
  route.path === "/device"
    ? "我的设备"
    : route.path === "/help"
      ? "使用指南"
      : "发现曲谱",
);
const links = [
  {
    label: "发现曲谱",
    icon: "i-lucide-library",
    to: "/",
    exact: true,
    onSelect: () => (open.value = false),
  },
  {
    label: "我的设备",
    icon: "i-lucide-bluetooth",
    to: "/device",
    onSelect: () => (open.value = false),
  },
  {
    label: "使用指南",
    icon: "i-lucide-circle-help",
    to: "/help",
    onSelect: () => (open.value = false),
  },
];
</script>
<template>
  <UDashboardGroup unit="px" :persistent="false">
    <UDashboardSidebar
      v-model:open="open"
      :default-size="240"
      :min-size="210"
      :max-size="280"
      class="sidebar-shell"
      :ui="{ footer: 'border-t border-slate-200' }"
    >
      <template #header
        ><RouterLink to="/" class="brand"
          ><span class="brand-symbol">♮</span><span>琴谱库</span></RouterLink
        ></template
      >
      <template #default
        ><UNavigationMenu
          :items="links"
          orientation="vertical"
          class="w-full"
        />
      </template>
      <template #footer
        ><div class="sidebar-status">
          <span :class="['status-dot', { online: d.link }]" />
          <div>
            {{
              d.link
                ? d.link.kind === "demo"
                  ? "演示设备已连接"
                  : "蓝牙设备已连接"
                : "尚未连接设备"
            }}
          </div>
        </div></template
      >
    </UDashboardSidebar>
    <UDashboardPanel id="library-panel">
      <template #header
        ><UDashboardNavbar :title="title"
          ><template #leading><UDashboardSidebarCollapse /></template
          ><template #right
            ><UBadge
              v-if="d.link?.kind === 'demo'"
              color="warning"
              variant="soft"
              >演示模式</UBadge
            ><UButton
              to="/device"
              icon="i-lucide-bluetooth"
              color="neutral"
              variant="outline"
              >{{ d.link ? "设备管理" : "连接设备" }}</UButton
            ></template
          ></UDashboardNavbar
        ></template
      >
      <template #body
        ><main class="main-content">
          <UAlert
            v-if="d.error"
            color="error"
            variant="soft"
            icon="i-lucide-circle-alert"
            :description="d.error"
            title="提示"
            class="mb-5"
          />
          <div v-if="d.stage" class="transfer-strip" aria-live="polite">
            <div>
              <strong>{{ d.transferTitle }}</strong
              ><span
                >{{ d.stage }}{{ d.transferKind === "demo" ? " · 演示" : "" }}
                <template v-if="d.totalBytes">
                  · 已确认 {{ formatBytes(d.savedBytes) }} /
                  {{ formatBytes(d.totalBytes) }} ·
                  {{ Math.ceil(d.savedBytes / BLOCK_BYTES) }} /
                  {{ Math.ceil(d.totalBytes / BLOCK_BYTES) }} 块</template
                ></span
              >
            </div>
            <UProgress
              v-if="d.totalBytes"
              :model-value="d.progress"
              class="max-w-48"
            /><UButton
              v-if="d.busy && d.stage === '正在传输'"
              size="xs"
              color="neutral"
              variant="outline"
              @click="d.pause"
              >暂停传输</UButton
            >
          </div>
          <RouterView />
          <footer class="site-footer">
            <span>琴谱库</span
            ><a
              href="https://github.com/W-JOSLIN-X/piano-score-library"
              target="_blank"
              rel="noopener noreferrer"
              >项目源码 ↗</a
            >
          </footer>
        </main></template
      >
    </UDashboardPanel>
  </UDashboardGroup>
</template>
