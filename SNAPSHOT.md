# 公开快照与证据边界

快照整理日期：2026-10-24。`fpga/` 与 `esp32/` 分别从当时的本地工程选择性复制；原工程、构建缓存、历史备份和个人录音未移动或清理。ESP32 源工程含尚未提交到其上游分支的改动，因此本仓是当前工作树快照，不代表其上游历史。

`website/` 于 2026-11-02 从团队网站工作树按 Git 跟踪文件复制；它包含该工作树中 `src/lib/ble.ts` 与 `tests/ble.test.ts` 的未提交改动，未复制网站的 `.git` 历史、`node_modules`、`dist` 或 `output`。原始维护仓库为 https://github.com/W-JOSLIN-X/piano-score-library 。

封存实机位流：`fpga/impl/pnr/midi_basic_synth_20261022_1941_PCM5102_USER_VERIFIED.fs`。SHA-256：`8479F2EDF73ECB4C0DDF4F70C60168FD5C2534DA671C8F4F285C80270A318534`。其配对报告给出 sys_clk 51.716 MHz、pixel_clk 29.585 MHz、setup/hold 违例端点 0/0。位流和报告与本快照 RTL 的版本关联由封存文件名及原工程记录维护；修改任何 RTL 后需重新综合布局布线，不可沿用该报告。

本快照离线验证：`fpga/sim/run_piano32_spectrum.ps1` 捕获 4096 个 HDL 样本，32 个预测数字分量均高于局部噪声底；`esp32/tests/test_analyze_bridge_log.py` 四项通过。以上均非模拟输出或整机延迟的仪器实测。ESP32 完整桌面回归需要可用的 C 编译器、ESP-IDF Python 环境及独立曲谱网站样本，本次未在公开快照中完整运行。Gowin 综合、布局布线及上板烧录也未因整理仓库而重做。

公开仓库中的旧测试脚本可能含开发机工具链默认路径；这些是路径示例，不是通用安装位置。请按自己的 ESP-IDF、编译器及串口位置传入参数。`docs/` 收录最终版技术报告 PDF 和可编辑正文；报告中的实机图片、设计示意、RTL 与时序数值按各自来源标注。
