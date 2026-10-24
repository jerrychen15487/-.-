# 弦域·织音

Tang Mega 60K FPGA 实时电子乐器系统。USB-MIDI 电钢琴和摇杆经 ESP32-S3 输入；FPGA 用 HDL 逐样本合成四声部音频，并通过标准 I²S 输出到 PCM5102A。系统另含 HDMI 波形／频谱、microSD 单曲库、BLE 曲谱传输、五线谱／简谱和钢琴块练习反馈。

## 仓库结构

- `fpga/`：Gowin 工程、RTL、约束、仿真脚本与 2026-10-22 19:41 用户确认出声位流及配对时序报告。
- `esp32/`：ESP-IDF v6.1 工程的现役源码、构建脚本与测试。该目录是工作区快照，包含本地尚未提交到上游 `codex/v2.0` 的摇杆／延迟诊断改动。
- `docs/`：参赛简介、技术报告文本、视频分镜和提交边界。

曲谱网页由团队独立公开维护：[piano-score-library](https://github.com/W-JOSLIN-X/piano-score-library)。本仓不复制其开发历史和本地未提交改动；提交页应同时引用该原始仓库。网页使用 Nuxt UI Templates 的 MIT 授权；曲目素材的来源和授权见网页原仓。

## 能力与限制

当前是 **四音复音**，不是 32 音复音。P 钢琴音色对每个活跃声部计算至多 32 个加法分量，A 音色提供单音 32 分量演示；分量运算由 FPGA 在一个采样周期内分时完成。实际音频时钟比值为 `50 MHz / 1024 = 48,828.125 Hz`，不是精确 48,000 Hz。FPGA 实现音符分配、相位、ADSR、混音、回声与 I²S；ESP32 不合成音频。实机出声是用户观察，完整琴键动作到 DAC 模拟输出的 ≤10 ms／≤5 ms 延迟尚未测定。

电容触摸、超声测距、光电拨弦、32 音复音、FM／物理弦建模均为未完成方向，不在当前实机版本中。

## 构建与验证

1. 在 Gowin 打开 `fpga/midi_basic_synth.gprj`。顶层 `top`，器件 `GW5AT-LV60PG484AC1/I0`；系统域约束 50 MHz。用户自行运行综合、布局布线和烧录。任何 RTL 改动后的时序必须重测，不能沿用封存报告。
2. ESP32 使用 ESP-IDF v6.1。参考 `esp32/tools/build.ps1`，USB 输入、READY、BLE-UART 和摇杆当前配置需显式启用 `-JoystickDiag -SteadyMod -JoystickButtons -UartTx 17 -UartRx 18`。本地默认 IDF 路径仅是开发机设置，应替换成自己环境的路径。
3. 测试文件见 `fpga/sim/`、`fpga/tests/` 与 `esp32/tests/`。本仓不包含 Gowin 构建缓存、ESP-IDF build 目录或旧备份。

封存位流 SHA-256：`8479F2EDF73ECB4C0DDF4F70C60168FD5C2534DA671C8F4F285C80270A318534`。配对时序报告显示 sys_clk Fmax 51.716 MHz、pixel_clk Fmax 29.585 MHz、setup/hold 违例端点 0/0。此证据仅证明该位流的静态时序和用户观察到的功能，不能证明整机延迟。

## 硬件安全

两板控制信号按 3.3 V 接线并共地；PCM5102A 模块 VIN 按实物规格接 5 V，5 V 不得接到 FPGA 的 BCK/LRCK/DIN 或 ESP32 ADC。先断电改线，供电与焊桥以实测通断为准。PCM5102A LINE OUT 接有源音箱或线路输入，不直推无源扬声器。

## 公开范围

本仓只纳入完成该作品所需源代码、测试、配置、少量技术文档和一份可追溯实机位流。个人录音、帐号、蓝牙设备标识、全部历史备份及其他比赛资料不随仓库发布。未另行声明时，本仓代码不附加统一开源许可证；第三方网站源码及其许可仍以原仓为准。
