import { ref, shallowRef } from "vue";
import {
  BleLink,
  DemoLink,
  DemoStorage,
  validateCaps,
  validateStatus,
  listEntries,
  transferScore,
  validateDeviceSupport,
  deleteEntry,
  matchesScore,
  TransferPaused,
  TransferStopped,
  UnknownCommit,
  UnknownDelete,
  DeviceError,
  TransportError,
  type DeviceLink,
  type Caps,
  type Status,
  type Entry,
  type Changed,
} from "../lib/device";
import { parseScore, type Score } from "../lib/pseq";
import { ScoreSourceCache, fingerprint, type SourceFingerprint } from "../lib/source-cache";
import { CMD, jsonBytes } from "../lib/wire";
const link = shallowRef<DeviceLink>(),
  caps = ref<Caps>(),
  status = ref<Status>(),
  entries = ref<Entry[]>([]),
  directory = ref<"unknown" | "loading" | "known">("unknown");
const busy = ref(false),
  error = ref(""),
  progress = ref(0),
  stage = ref(""),
  transferTitle = ref(""),
  savedBytes = ref(0),
  totalBytes = ref(0);
const transferKind = ref<"ble" | "demo">();
const demoStorage = new DemoStorage(),
  sources = new ScoreSourceCache();
type Operation = {
  device: string;
  id: string;
  action: "upload" | "delete";
  kind: "ble" | "demo";
  title: string;
  bytes: number;
};
let currentOperation: Operation | undefined;
const pendingCommits = new Map<string, { source: SourceFingerprint; operation: Operation }>(),
  pendingDeletes = new Map<string, { entry: Entry; operation: Operation }>();
let abort: AbortController | undefined,
  dirty = false,
  scheduled = false,
  changeRevision = 0;
let latestChanged: Changed | undefined;
const message = (e: unknown) => (e instanceof Error ? e.message : String(e));
function startOperation(
  current: DeviceLink,
  id: string,
  title: string,
  bytes: number,
  action: Operation["action"],
) {
  const operation: Operation = {
    device: current.identity, id, title, bytes, action, kind: current.kind,
  };
  currentOperation = operation;
  transferTitle.value = title;
  transferKind.value = current.kind;
  totalBytes.value = bytes;
  savedBytes.value = 0;
  progress.value = 0;
  stage.value = operation.action === "upload" ? "准备传输" : "正在删除";
  return operation;
}
function reconcileOperation(operation: Operation, text: string, stored = false) {
  // A later operation, including one with the same UUID, owns its own result.
  if (currentOperation !== operation) return;
  transferTitle.value = operation.title;
  transferKind.value = operation.kind;
  totalBytes.value = stored ? operation.bytes : 0;
  savedBytes.value = stored ? operation.bytes : 0;
  progress.value = stored ? 100 : 0;
  stage.value = text;
}
async function refresh() {
  const current = link.value;
  if (!current) return;
  directory.value = "loading";
  try {
    const revision = changeRevision;
    const nextStatus = validateStatus(await current.request(CMD.STATUS));
    if (link.value !== current) return;
    // A notification received while STATUS was in flight is newer than that
    // snapshot. Publish before LIST so subsequent notifications also win.
    status.value = changeRevision !== revision && latestChanged
      ? { ...nextStatus, ...latestChanged }
      : nextStatus;
    const nextEntries = await listEntries(current);
    if (link.value !== current) return;
    entries.value = nextEntries;
    directory.value = "known";
    for (const [key, { source, operation }] of pendingCommits)
      if (key === current.identity + ":" + source.id) {
        if (
          nextEntries.some((e) => e.entry_state === 2 && e.id === source.id &&
            e.total_bytes === source.total_bytes && e.file_crc === source.file_crc)
        ) {
          reconcileOperation(operation, "已核对保存成功", true);
          pendingCommits.delete(key);
        }
      }
    for (const [key, { entry, operation }] of pendingDeletes)
      if (key === current.identity + ":" + entry.id) {
        const exists = nextEntries.some((e) => e.id === entry.id);
        if (!exists) sources.delete(entry);
        reconcileOperation(operation, exists
          ? "该 UUID 仍存在，未确认删除；不会自动重试"
          : "已核对曲目不存在");
        pendingDeletes.delete(key);
      }
  } catch (e) {
    if (link.value === current) {
      directory.value = "unknown";
      entries.value = [];
    }
    throw e;
  }
}
function scheduleRefresh() {
  dirty = true;
  if (scheduled || busy.value || !link.value) return;
  scheduled = true;
  queueMicrotask(() => {
    scheduled = false;
    if (!busy.value && dirty && link.value) {
      dirty = false;
      void guarded(refresh);
    }
  });
}
async function guarded(fn: () => Promise<void>) {
  if (busy.value) return;
  busy.value = true;
  error.value = "";
  try {
    await fn();
  } catch (e) {
    error.value = message(e);
  } finally {
    busy.value = false;
    if (dirty) scheduleRefresh();
  }
}
function bind(current: DeviceLink) {
  latestChanged = undefined;
  current.onDisconnect = () => {
    if (link.value !== current) return;
    link.value = undefined;
    caps.value = undefined;
    status.value = undefined;
    entries.value = [];
    directory.value = "unknown";
    dirty = false;
    error.value = "连接已断开；已确认进度保留，重连后查询设备";
  };
  current.onChanged = (event) => {
    if (link.value !== current) return;
    changeRevision++;
    latestChanged = event;
    if (status.value?.generation !== event.generation)
      directory.value = "loading";
    if (status.value) status.value = { ...status.value, ...event };
    if (event.mode !== 0 && abort && !abort.signal.aborted) abort.abort("mode");
    scheduleRefresh();
  };
  link.value = current;
}
async function upload(score: Score, replace = false) {
  const current = link.value,
    c = caps.value;
  if (!current || !c) throw Error("请先连接设备");
  const operation = startOperation(
    current, score.id, String(score.meta.title), score.bytes.length, "upload",
  );
  let began = false;
  try {
    if (replace) validateDeviceSupport(parseScore(score.bytes), c);
    const existing = (await listEntries(current)).find((e) => e.id === score.id);
    if (existing?.entry_state === 2) {
      if (!replace) throw Error("设备已有完整曲目，请使用明确的“重新下载”操作");
      await deleteEntry(current, existing);
      sources.delete(existing);
      entries.value = entries.value.filter((e) => e.id !== existing.id);
    }
    abort = new AbortController();
    await transferScore(current, score, c, abort.signal, (bytes, text) => {
      if (!began) {
        began = true;
        sources.remember(score);
      }
      savedBytes.value = bytes;
      progress.value = (bytes / score.bytes.length) * 100;
      stage.value = abort?.signal.aborted && abort.signal.reason === "user" && text === "正在传输"
        ? "正在暂停，等待设备确认"
        : text;
    });
  } catch (e) {
    if (e instanceof UnknownCommit) {
      pendingCommits.set(operation.device + ":" + operation.id, { source: fingerprint(score), operation });
      stage.value = "保存结果未确认";
    } else if (e instanceof UnknownDelete) {
      pendingDeletes.set(operation.device + ":" + operation.id, { entry: e.entry, operation });
      stage.value = "删除结果未确认，重连后先核对目录";
    } else if (e instanceof TransferPaused) {
      stage.value = "已暂停，进度保留";
    } else if (e instanceof TransferStopped) {
      stage.value = "已停止，回到管理状态后手动续传";
    } else if (e instanceof DeviceError) {
      stage.value = "设备拒绝下载";
    } else {
      stage.value = began || e instanceof TransportError
        ? "传输中断，请查询设备进度"
        : "下载未开始";
    }
    if (e instanceof TransferPaused || e instanceof TransferStopped) return;
    throw e;
  } finally {
    abort = undefined;
    if (link.value === current) {
      dirty = false;
      await refresh().catch((e) => {
        error.value =
          stage.value === "已保存"
            ? `保存成功；目录待刷新：${message(e)}`
            : message(e);
      });
    }
  }
}
async function resume(entry: Entry, replace = false) {
  let score = sources.get(entry);
  if (!score) {
    const response = await fetch(
      import.meta.env.BASE_URL + "scores/catalog.json",
    );
    if (!response.ok)
      throw Error("预置目录无法加载，请稍后重试或重新导入原文件");
    const catalog = (await response.json()) as { id: string; file: string }[],
      item = catalog.find((i) => i.id === entry.id);
    if (!item) throw Error("请在曲库页面重新导入原 .pseq 文件，再点击下载续传");
    const file = await fetch(import.meta.env.BASE_URL + item.file);
    if (!file.ok) throw Error("原曲目文件无法加载");
    score = parseScore(new Uint8Array(await file.arrayBuffer()));
  }
  if (!replace && !matchesScore(entry, score))
    throw Error("原文件 UUID、长度或 CRC 不一致，请手动删除未完成曲目后再下载");
  await upload(score, replace);
}
export function useDevice() {
  return {
    link,
    caps,
    status,
    entries,
    directory,
    busy,
    error,
    progress,
    stage,
    transferTitle,
    transferKind,
    savedBytes,
    totalBytes,
    connect: (demo = false) =>
      guarded(async () => {
        link.value?.close();
        const current = demo ? new DemoLink(demoStorage) : new BleLink();
        stage.value = "";
        progress.value = 0;
        bind(current);
        try {
          caps.value =
            current instanceof BleLink
              ? await current.connect()
              : validateCaps(await current.request(CMD.CAPS));
          await refresh();
        } catch (e) {
          if (!caps.value) current.close();
          throw e;
        }
      }),
    refresh: () => guarded(refresh),
    disconnect: () => {
      link.value?.close();
    },
    upload: (score: Score, replace = false) =>
      guarded(() => upload(score, replace)),
    resume: (entry: Entry) => guarded(() => resume(entry)),
    redownload: (entry: Entry) => guarded(() => resume(entry, true)),
    pause: () => {
      if (abort && stage.value === "正在传输") {
        stage.value = "正在暂停，等待当前块确认";
        abort.abort("user");
      }
    },
    remove: (entry: Entry) =>
      guarded(async () => {
        const current = link.value;
        if (!current) throw Error("设备未连接");
        const operation = startOperation(current, entry.id, entry.title, 0, "delete");
        try {
          await deleteEntry(current, entry);
          sources.delete(entry);
          stage.value = "已删除";
        } catch (e) {
          if (e instanceof UnknownDelete) {
            pendingDeletes.set(operation.device + ":" + operation.id, { entry, operation });
            stage.value = "删除结果未确认，重连后先核对目录";
          }
          throw e;
        } finally {
          if (link.value === current) {
            dirty = false;
            await refresh().catch((e) => {
              error.value = "目录待刷新：" + message(e);
            });
          }
        }
      }),
    pauseActive: () =>
      guarded(async () => {
        const current = link.value,
          id = status.value?.active_id;
        if (!current || !id) return;
        const r = await current.request<{ request_type: number; id: string }>(
          CMD.PAUSE,
          jsonBytes({ id }),
        );
        if (r.request_type !== CMD.PAUSE || r.id !== id)
          throw Error("暂停确认无效");
        await refresh();
      }),
    toggleDemoState: () => {
      if (link.value instanceof DemoLink)
        demoStorage.setMode(demoStorage.mode === 0 ? 3 : 0);
    },
    restartDemo: () => {
      if (link.value instanceof DemoLink) {
        link.value.close();
        demoStorage.restart();
      }
    },
    demoLocalDelete: (entry: Entry) => {
      if (link.value instanceof DemoLink) {
        demoStorage.localDelete(entry.id);
        sources.delete(entry);
      }
    },
  };
}
