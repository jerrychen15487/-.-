# midi_basic_synth 工作约定

- 本工程是 Tang Mega 60K 的实时 MIDI 合成器：ESP32-S3 输入桥接到 FPGA，FPGA 合成音频，同时驱动板载 PT8211 和外置 PCM5102A；另有 HDMI、SD 曲谱和练习显示。
- 顶层 RTL 为 `src/top.v`，约束为 `src/midi_basic_synth.cst`，Gowin 工程为 `midi_basic_synth.gprj`；离线回归在 `sim/` 与 `tests/`。`README.md` 的旧日期章节是历史过程，不是当前状态。
- 用户自行在 Gowin 完成综合、布局布线、生成位流和烧录。修改 RTL 后不要沿用旧 Fmax；先按对应源码通过仿真，再由新报告核查 50 MHz 系统域、setup/hold 违例和未布线网络。
- 2026-10-24：用户报告 2026-10-22 19:41 位流的 PCM5102A 声路稳定发声；封存位流与 SHA、接线和证据边界见 `docs/PCM5102A-I2S-接线与验收-2026-10-22.md`。这不是完整琴键到模拟输出延迟 ≤10 ms 的测量结论。
- 保留已有位流、报告和备份；不要覆盖已验证基线。硬件排查以断电接线和实物测量为准，不能把商品示意图或 RTL 仿真当作实物导通证据。
