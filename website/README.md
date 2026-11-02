# 琴谱库

[打开网站](https://w-joslin-x.github.io/piano-score-library/) · [版本发布](https://github.com/W-JOSLIN-X/piano-score-library/releases)

2.1.0：浏览三首完整的布格缪勒作品，预览五线谱、简谱和无声钢琴块，导入或保存 PSC2 2.0 `.pseq` 曲目包，通过 BLE v2 管理配套设备曲库。

本版拒绝全零曲目 UUID，并修复演示设备对未完成曲目的 COMMIT 活动归属检查；补充名额、删除及 Unicode 标题边界回归。曲目包格式仍为 PSC2 2.0，BLE 协议仍为 v2，三首正式曲目无需重新下载。

三种预览使用包中默认四分音符 BPM，支持无声播放、暂停、拖动、小节高亮和自动翻页。设备目录区分完整与未完成曲目；支持暂停保留进度、重连续传、显式删除后重新下载及本地目录变化通知。网站不控制设备练习、翻页、BPM 或模式。

真实 BLE 尚未完成 ESP32/FPGA 硬件联调。演示设备仅使用浏览器内存，断连和演示重启保留记录，刷新网页后清空；演示保存不代表硬件保存。网页不转换 PDF、MIDI 或 MusicXML，也不再接受 PSC1。

## 运行

建议 Node.js 24 LTS（最低 22.19）。

```sh
npm ci
npm run dev
npm test
npm run typecheck
npm run build
npm run preview
```

访问终端显示的 `/piano-score-library/` 路径。推送 `main` 后，GitHub Actions 运行测试、构建并部署 Pages。版本使用 Git 标签和 GitHub Releases 管理。

## 来源与许可

基于官方 [Nuxt UI Vue Dashboard](https://github.com/nuxt-ui-templates/dashboard-vue)，使用 Vue、TypeScript、Vite 和 Nuxt UI。代码保留 [MIT 许可](LICENSE)。正式曲库采用 Mutopia 标记为 Public Domain 的 Op.100 No.5《天真》、No.6《进步》和 No.2《阿拉贝斯克》完整版本；来源、固定哈希、演奏路线和离线排版步骤见 [来源说明](sources/README.md)。默认 BPM 来自对应版本的播放设置，不称作原作权威节拍器速度；三首均无踏板评分参考。

工程包独立放在 `tests/fixtures/packages/`，采用 CC0-1.0，不进入公开曲库。协议黄金字节、文件/像素清单与离线判分输入向量见 [联调入口](tests/fixtures/HANDOFF.md)。普通测试与网站构建不需要安装 LilyPond；`npm run generate:scores` 使用已准备的离线排版输出，只生成待审核候选，不自动替换正式 catalog。
