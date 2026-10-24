# 电钢琴、实时 SPI 与曲谱 UART 协议

字段版本基线：2026-10-11；实现状态更新：2026-10-12。MIDI/SPI为现有固件基线；网页已迁移PSC2/BLE v2并提供样本，ESP32的UART/BLE实现与检查见VALIDATION，真实联调仍待完成。本文是字段、编号、端序的唯一主来源。产品规则见[项目目标与方法](../docs/项目目标效果与实现方法.md)，开发顺序见[FPGA计划](../docs/FPGA开发与联调计划.md)。整数小端、无隐式填充；UUID是去掉连字符后从左到右的16字节，不使用Windows GUID混合端序。命令/事件编号按十六进制，其他数值默认十进制。

## 1. 电钢琴输出

### 1.1 三字节 MIDI 1.0 消息

| 偏移 | 字段 | 含义 |
|---:|---|---|
| 0 | status | 高四位消息类型，低四位n为通道0～15，界面显示n+1 |
| 1 | data1 | 音符或控制器编号，0～127 |
| 2 | data2 | 力度、释放力度或CC值，0～127 |

| status | data1 | data2 | 处理 |
|---|---|---|---|
| 9n | 音符 | 1～127 | 音符开始 |
| 9n | 音符 | 0 | 规范化为音符结束 |
| 8n | 音符 | 释放力度 | 音符结束，保留原值 |
| Bn | 控制器 | 原值 | 所有CC保留 |
| En | 低7位 | 高7位 | 弯音值=data1+(data2<<7)，当前跳过 |

本琴实测：按键主要在通道1，首批174次按键有68种力度（3～127），不是强弱两值。CC64（40H）踩下60H=96，松开00H。延音阈值：≥64开启，<64关闭。

一次踏板变化伴随B0、E2、E3、E4、E5五条消息，**不是一个固定五消息协议帧**。B0 40 vv按CC转发，四条弯音独立跳过，不凑组、不作为未来滑音传感器输入。

### 1.2 四字节 USB-MIDI 1.0 事件包

| 偏移 | 字段 | 含义 |
|---:|---|---|
| 0 | Cable/CIN | 高四位Cable；低四位CIN：8结束、9开始、B控制器、E弯音 |
| 1～3 | MIDI消息 | status、data1、data2 |

一个Bulk IN完成可以包含多条四字节事件，按实际有效长度解析。现有转换器检查CIN/status一致、数据7位、长度为4的倍数；其他消息统计跳过。不支持MIDI 2.0、SysEx或私有协议。

本琴电脑USB抓包：VID=1B3F、PID=6201、全速、接口1/alt0、Bulk IN=81H、MPS=64、观测Cable0。固件仍按描述符识别，不固定VID/PID。MIDI-OX的TIMESTAMP/PORT是电脑显示字段，不是USB包头。

| USB输入（十六进制） | 含义 |
|---|---|
| 09 90 3C 64 | 通道1，音符60，力度100 |
| 08 80 3C 40 | 松键，释放力度64 |
| 09 90 3C 00 | 零力度开始，按松键处理 |
| 0B B0 40 60 | 本琴踩下踏板 |
| 0B B0 40 00 | 松开踏板 |
| 0E E2 40 60 | 踏板伴随弯音，跳过 |

证据：[MIDI实测](../docs/电钢琴MIDI-OX实测分析-2026-10-10.md)、[USB抓包](../captures/usb/2026-10-11/pc-session-01/README.md)。

## 2. ESP32 → FPGA 实时 SPI

### 2.1 六字节事件帧

| 偏移 | 长度 | 字段 | 取值 |
|---:|---:|---|---|
| 0 | 1 | type | 01开始，02结束，03 CC；其他未分配 |
| 1 | 1 | route | 高四位Cable、低四位通道，均0～15 |
| 2 | 1 | parameter | 音符或CC编号，0～127 |
| 3 | 1 | value_lo | 原始力度、释放力度或CC值 |
| 4 | 1 | value_hi | 当前0，与前一字节组成u16 |
| 5 | 1 | reserved | 当前0 |

| USB输入 | SPI输出 |
|---|---|
| 09 90 3C 64 | 01 00 3C 64 00 00 |
| 08 80 3C 40 | 02 00 3C 40 00 00 |
| 09 90 3C 00 | 02 00 3C 00 00 00 |
| 0B B0 40 60 | 03 00 40 60 00 00 |
| 0B B0 40 00 | 03 00 40 00 00 00 |

未来外部传感器的滑音/颤音使用新type定义，保留16位值及保留字节；当前不分配有效含义，两端不得自行占号。

### 2.2 接线与事务

| 项目 | 约定 |
|---|---|
| 主从/电平 | ESP32 SPI2主机，FPGA从机；3.3V兼容IO，共地 |
| 时序 | Mode0、10MHz、MSB first，无MISO |
| ESP32引脚 | SCLK=12、MOSI=11、CS=10、READY=13 |
| 边界 | 一次CS拉低恰好48时钟/6字节，完成后拉高 |
| READY | 高允许启动一帧；启动后FPGA必须接完当前帧；低时ESP32阻塞等待，不忙等 |
| 当前测试 | READY可编译旁路；启动显示BYPASS。FPGA联调前恢复真实READY |
| 校验 | 无帧头、CRC、序号、ACK、时间戳；READY不是应答 |
| 断连 | ESP32取消未发送事件，不发停音/复位帧 |

FPGA完整收帧后立即用本地时钟打点。断连可能漏松键而卡音，FPGA提供本地全部停音；不能靠“长时间无事件”判断断连。参考曲目不经SPI自动发声。

## 3. ESP32 ↔ FPGA 曲谱 UART v2

### 3.1 外层

UART1，1,000,000 baud、8N1、全双工、无RTS/CTS、3.3V兼容IO、共地。TX/RX具体GPIO在接线联调时登记，避开USB19/20、SPI10～13、调试43/44及测量引脚。UART0/CH340只用于日志。

| 偏移 | 长度 | 字段 | 约定 |
|---:|---:|---|---|
| 0 | 2 | magic | A5 5A |
| 2 | 1 | version | 02，不兼容旧v1载荷 |
| 3 | 1 | type | 命令号 |
| 4 | 4 | session | 请求方生成的非零会话号 |
| 8 | 4 | seq | 从1递增，重试同号同字节 |
| 12 | 2 | payload_len | N，0～1024 |
| 14 | 2 | reserved | 0 |
| 16 | N | payload | 按命令解释 |
| 16+N | 4 | crc32 | 覆盖bytes[2:16+N] |

总长N+20，最大1044字节。不另加帧尾/转义，载荷中A5 5A是普通数据。组帧间隔超时100ms；超长/坏CRC丢弃并重同步，不使用损坏的session/seq回错。语义错误才返回ERROR。

CRC-32/ISO-HDLC：反射多项式EDB88320H，初值/最终异或FFFFFFFFH；ASCII `123456789` → CBF43926H，线上`26 39 F4 CB`。文件/段/帧同算法；CRC检错不认证。

会话1、序号1、空载荷CAPS请求示例（含CRC）：

```text
A5 5A 02 01 01 00 00 00 01 00 00 00 00 00 00 00 1E 28 4C BA
```

### 3.2 命令、应答

u8/u16/u32/u64均无符号；id[16]为UUID，曲目ID不得全零（nil UUID）；全零仅供STATUS表示无活动曲目。r为置零保留字段。字段按表紧密排列。ACK=80、回显session/seq，载荷先带`request_type:u8,r[3]`，随后接下表结果。ERROR=FF：`request_type:u8,r:u8,error:u16,next_block:u32`；不适用的next_block=FFFFFFFFH。

| type | 名称 | 请求载荷 | ACK前缀之后的结果 |
|---|---|---|---|
| 01 | CAPS | 空 | CAPS记录 |
| 02 | STATUS | 空 | STATUS记录 |
| 03 | LIST | generation:u32,cursor:u32,limit:u16,r:u16 | generation:u32,next_cursor:u32,count:u16,r:u16,条目[count] |
| 10 | BEGIN | id[16],total_bytes:u32,file_crc:u32,block_bytes:u16,package_major:u16,total_blocks:u32,capabilities:u32,title_len:u16,r:u16,title[title_len] | PROGRESS记录 |
| 11 | DATA | id[16],block_index:u32,data[1..512] | PROGRESS记录 |
| 12 | COMMIT | id[16],total_bytes:u32,file_crc:u32 | id[16],file_crc:u32,entry_state:u8=2,r[3] |
| 13 | PAUSE | id[16] | PROGRESS记录，保留完整块 |
| 14 | DELETE | id[16] | id[16],deleted:u8,r[3]，不存在时deleted=0仍成功 |
| 90 | CHANGED | 非请求：FPGA通知 | payload=generation:u32,mode:u8,phase:u8,r:u16；session=seq=0，不应答 |
| 80 / FF | ACK / ERROR | 非请求 | 见上 |

BEGIN固定40字节加标题；title_len为1～384字节且标题为1～128个Unicode标量，UTF-8无NUL或C0控制字符。本地允许只显示UUID，FPGA可保存标题供网站显示，无须解析中文字库。block_bytes=512，package_major=2，total_blocks=ceil(total_bytes/512)。DATA块号从0起，数据长=payload_len−20；除尾块外512字节，尾块长由文件总长决定。无需尾帧位。

PROGRESS为28字节：`id[16],next_block:u32,total_blocks:u32,saved_bytes:u32`；saved_bytes=min(next_block×512,total_bytes)。所有进度均指FPGA已持久化内容。

| CAPS记录偏移（不含ACK前缀） | 类型 | 字段 |
|---:|---|---|
| 0/2/4/6 | u16各 | uart_version=2、package_major=2、max_payload=1024、block_bytes=512 |
| 8/12/16/20 | u32各 | max_file_bytes、max_notes、max_complete_songs、max_partial_songs |
| 24/28 | u32各 | max_sections、max_pages |
| 32/34 | u16各 | profile_count、storage_flags（bit0断电续传，必须1） |
| 36 | u16数组 | profiles，最多32项，当前定义profile1 |

STATUS共40字节：`mode:u8,phase:u8,r:u16,generation:u32,free_bytes:u64,active_id[16],next_block:u32,total_blocks:u32`。mode：0曲库管理、1自由演奏、2曲谱阅读、3跟谱练习（含暂停）；phase：0空闲、1接收、2校验提交。无活动下载时active_id/两个块字段全0；已暂停任务由LIST列出。

LIST条目固定44字节加标题：`id[16],entry_state:u8,r[3],total_bytes:u32,file_crc:u32,capabilities:u32,next_block:u32,total_blocks:u32,title_len:u16,r:u16,title[title_len]`。entry_state：1未完成、2完整；完整项next_block=total_blocks。首次LIST用generation=0,cursor=0；后续使用返回的generation和cursor；next_cursor=FFFFFFFFH结束。limit为1～16，上游BLE每次请求1项；实际返回数还受1024字节限制。generation从1开始并随目录持久保存，目录结构变化递增；块进度变化不改目录排序。跨页generation不同返回STALE_LIST，重新查询；进度可用STATUS刷新。

| error | 名称 | 含义 |
|---|---|---|
| 0001 | BUSY | 当前模式或活动事务不允许 |
| 0002 | NO_SPACE | 存储或完整/部分曲目名额不足 |
| 0003 / 0004 | UNSUPPORTED_VERSION / UNSUPPORTED_PROFILE | 版本/谱面规格不支持 |
| 0005 | BAD_BLOCK | 块号或块长错误，附期望next_block |
| 0006 / 0007 | BAD_FILE_CRC / BAD_PACKAGE | 整文件CRC/结构错误 |
| 0008 | STORAGE_ERROR | 数据、进度或删除持久化失败 |
| 0009 | CONTENT_MISMATCH | 同UUID部分内容的长度/CRC等不同 |
| 000A / 000B | NOT_FOUND / STALE_LIST | 部分曲目不存在/目录变化 |
| 000C | ALREADY_STORED | 完整曲目存在，重新下载前先DELETE |
| 000D | BAD_REQUEST | 字段、长度、序号或命令非法 |

TIMEOUT、FPGA_LINK_DOWN是ESP32/网站本地链路错误，不冒充FPGA已响应。

### 3.3 事务规则

| 情形 | 规则 |
|---|---|
| 下载 | BEGIN→顺序DATA/ACK→COMMIT/ACK；未完整提交不可选曲 |
| 恢复 | BEGIN的UUID、长度、CRC、块规格、包版本、能力与部分记录一致才返回next_block；不同返回普通CONTENT_MISMATCH，由用户DELETE后重下 |
| 持久ACK | 数据块和新进度均可靠保存后才ACK，掉电不得丢失已ACK块 |
| 重复块 | 已存字节相同则返回当前进度，不同报CONTENT_MISMATCH；跳号报BAD_BLOCK |
| 暂停/断线/复位 | 已确认块保留；未确认块可丢弃或已完整保存，重连以FPGA进度为准 |
| 多任务 | 只一个活动传输，可保留多首未完成曲目，容量由CAPS报告；BEGIN检查部分名额与空间，COMMIT发布时检查完整名额，不在BEGIN预占完整名额 |
| 切换模式 | 停止接纳新块，当前存储操作完成或安全中止后再切换；已开始COMMIT先完成或明确失败 |
| 非管理状态 | BEGIN/DATA/COMMIT/DELETE返回BUSY；查询可用，PAUSE可幂等返回已有进度 |
| 重下完整曲目 | 网站显式DELETE该UUID，确认后BEGIN；BEGIN绝不暗删完整曲目；旧内容删除后下载失败不恢复旧版 |
| 结果不明 | 重连/复位后先LIST/STATUS核对长度/CRC和状态，不盲重放DELETE，不把提交超时当未保存 |
| 删除 | 网站或FPGA本地按UUID删除完整/部分内容与进度，可靠完成后更新目录并通知CHANGED；管理状态可串行删除非活动曲目B，保留活动曲目A；删除活动曲目则清除其活动状态 |
| 完成 | 部分曲目须为当前活动曲目才能COMMIT；数据100%后还要校验文件和结构、可靠发布，才COMMIT成功（完整项的幂等COMMIT例外，且不得清除其他活动任务） |

会话内一次仅一个在途请求，缓存最近完整请求/响应；同号同字节重试返回同结果，同号不同内容拒绝，较旧seq不再执行。重连先CAPS/STATUS建立新会话，旧会话失效；会话去重不替代复位后的持久进度核对。重复COMMIT遇到同UUID/长度/CRC已完整则直接成功。ESP32自主查询仅在没有网页连接且无在途请求时使用独立会话；网页连接后停止自主请求，由网页CAPS建立新的管理会话。旧管理会话请求不再执行；活动部分数据不因换会话删除，新会话可BEGIN同UUID恢复。FPGA主动CHANGED不占请求序号，不建立多个活动下载。

普通请求等待5秒，COMMIT30秒；超时最多重试2次，共3次。ESP32不叠加自动重试，由网站决定重发。存储须在预算内响应，否则双方联调统一修订。通知不需要可靠逐条重放，丢失后靠查询恢复。

### 3.4 BLE对应关系

服务`e6340001-8d7a-4e31-9ab0-43c800000001`；RX写特征`e6340002-8d7a-4e31-9ab0-43c800000001`；TX通知`e6340003-8d7a-4e31-9ab0-43c800000001`，沿用现有UUID。

BLE也用v2外层/命令号，控制与响应保持有界JSON，DATA为上述UUID+块号+字节。ESP32转换JSON↔UART二进制，session/seq及文件字节不变。GATT初始20字节分片，再按真实ATT能力调整；GATT应答不是持久化ACK。BLE常开，FPGA模式决定是否允许下载/删除。JSON映射见[网页/ESP32计划](../docs/曲库网页与ESP32开发方案.md)。当前网页已使用v2；历史BLE v1不能直连本章v2。

### 附录 A：PSC2 2.0 曲目包

`.pseq`扩展名；64字节头、32字节段目录项，数据段4字节对齐、填充0。旧PSC1 1.0需明确拒绝或离线转换，不能直接按新语义解释。

#### A.1 文件头

| 偏移 | 长度 | 字段 | 约定 |
|---:|---:|---|---|
| 0 | 4 | magic | ASCII PSC2 |
| 4/6 | 2各 | major/minor | 2/0 |
| 8 | 4 | total_bytes | 全文件含填充 |
| 12 | 16 | song_id | 非全零UUID，与BEGIN一致 |
| 28 | 4 | revision | 元数据修订号，不代替CRC |
| 32 | 4 | duration_ticks | 展开后结束位置 |
| 36/38 | 2各 | section_count/header_bytes | 段数/64 |
| 40 | 4 | directory_offset | 64 |
| 44 | 4 | capabilities | bit0参考练习、bit1五线谱、bit2简谱，其余0 |
| 48 | 4 | note_count | NOTE数量 |
| 52/54 | 2各 | ppq/default_bpm | 960/四分音符每分钟次数，20～300 |
| 56 | 8 | reserved | 0 |

时间统一tick；`秒=tick×60/(960×BPM)`。全曲单一BPM，可在练习前或暂停时修改为20～300整数BPM；范围为工程参数，不是音乐标准。FPGA保留定点余数。原谱分段速度在制谱时明确选择全曲速度，不提供变速段。

#### A.2 段目录

| 偏移 | 类型 | 字段 |
|---:|---|---|
| 0/4/6 | u32/u16/u16 | type/profile/flags（bit0必需，其余0） |
| 8/12/16 | u32各 | 绝对offset/length/count |
| 20/22/24/28 | u16/u16/u32/u32 | record_bytes/reserved=0/段crc32/reserved2=0 |

| type（十进制） | 名称 | 记录字节 | 数量与要求 |
|---:|---|---:|---|
| 1 | META | 0 | 恰好一段，profile0、count=1；UTF-8 JSON含title/source/generator_version；FPGA可跳过JSON |
| 2 | NOTE | 16 | 至多一段，profile0；练习必需且非空 |
| 3 | CC | 8 | 至多一段，profile0；有踏板目标时提供 |
| 4 | MEASURE | 16 | 至多一段，profile0；练习必需 |
| 5 | PAGE | 24 | 每profile至多一段；阅读必需 |
| 6 | BITMAP | 0 | 每profile至多一段，count=1；PAGE引用 |
| 7 | ANCHOR | 24 | 每profile至多一段；对应谱面练习必需 |
| 8 | SAFE_START | 4 | 至多一段，profile0；练习必需，首项0 |

固定记录段length=count×record_bytes；变长段record_bytes=0。已知语义段flags=1；未知必需段拒绝，未知可选段可跳过。每包至多一种非零profile，profile1=960×480/MONO1/stride120。高低声部共享NOTE，五线谱/简谱可同时存在。

#### A.3 NOTE，16字节

| 偏移 | 类型 | 字段 | 约定 |
|---:|---|---|---|
| 0/4 | u32各 | start_tick/duration_tick | duration>0，结束≤曲目结束 |
| 8 | u8 | pitch | 0～127 |
| 9 | u8 | dynamic | 0未指定、1pp、2p、3mp、4mf、5f、6ff |
| 10 | u8 | part_mask | 1低音部、2高音部、3两者共有，不识别真实手 |
| 11 | u8 | score_flags | bit0起音、bit1保持释放、bit2力度，其余0 |
| 12 | u32 | group_id | 同时起音组；组内start_tick相同 |

note_id是段内从0起的记录序号，按(start_tick,pitch,group_id)排序。力度评分位=1时dynamic必须1～6；缺参考时对应评分位0；保持释放/力度评分要求起音评分位也为1。力度区间不写入包，FPGA负责映射。

同音同时同长齐奏合并为part_mask=3；不能用一套实际按键动作表达的同音重叠在制作端拒绝。延音线合并，反复展开，重复击键分开；duration是手指按键时长，不包含踏板延音。

示例：960tick开始、持续480、高音部MIDI60、mf、三项评分、组7：

```text
C0 03 00 00 E0 01 00 00 3C 04 02 07 07 00 00 00
```

#### A.4 CC、MEASURE、SAFE_START

| 段 | 字段顺序 | 约束 |
|---|---|---|
| CC 8B | tick:u32,route:u8,controller:u8,value:u8,flags:u8 | route=0，controller/value为0～127；flags bit0参与评分，仅CC64允许，其余位0；按tick排序，同tick同控制器唯一 |
| MEASURE 16B | start_tick:u32,end_tick:u32,index:u32,numerator:u8,denominator_pow:u8,reserved:u16 | index从0递增；分母=2^denominator_pow（0～6），分子1～32；小节连续覆盖[0,duration_ticks)，首尾可不完整 |
| SAFE_START 4B | tick:u32 | 严格递增，含0且小于duration_ticks；其余取满足恢复条件的音符/小节起点 |

踏板参考初始松开。安全点t不得有任何声部音符满足start<t<end；t处新动作前的参考CC64为松开。相同tick先处理音符结束/踏板释放，再处理新起音/踏板踩下。t处新踩板可重新练。安全表包含上述候选中全部安全点，保证能找最近点；曲首0兜底。所有已提供的CC64（包括不评分片段）用于检查，未提供的目标不推测。

踏板评分将踩下与下一松开配为一项，配对两端评分标记一致；完整评分片段须有结束松开，缺参考片段不计分。只评开关及时间/保持，不评半踏板深度。

#### A.5 PAGE、BITMAP、ANCHOR

| 段 | 字段顺序 |
|---|---|
| PAGE 24B | page_id:u32,profile:u16,notation:u8,format:u8,width:u16,height:u16,stride:u16,reserved:u16,data_offset:u32,data_length:u32 |
| ANCHOR 24B | start_tick:u32,page_id:u32,measure_index:u32,x:u16,y:u16,width:u16,height:u16,notation:u8,reserved[3] |

notation=1五线谱/2简谱；format=1单色1bpp；page_id全包唯一。像素左上开始逐行，最高位在左，1黑0白；stride=ceil(width/8)，data_length=stride×height，data_offset为文件绝对偏移，位于同profile BITMAP内；不压缩，行末未用位0。profile1每页57,600字节；这是资源尺寸，不是HDMI分辨率。

每种用于练习的谱面、每个展开小节恰有一条ANCHOR；start_tick等于小节起点，按(start_tick,notation)排序，矩形非空且在页内。制谱避免单小节跨页，跨行时矩形覆盖该小节。反复可引用同页，页码不必递增。纯阅读可无ANCHOR，缺它不能开对应谱面练习；钢琴块不依赖位图。

#### A.6 装载检查

| 对象 | 必检 |
|---|---|
| 文件 | magic/版本/长度/UUID/能力与BEGIN一致，整文件CRC覆盖全部字节 |
| 目录 | 不越界、不重叠、不覆盖头/目录；单例、数量、记录长度及段CRC正确 |
| 时间 | 范围与加法不溢出，PPQ/BPM合法，音符/踏板/小节/安全点一致 |
| 资源 | profile/页/引用/像素长度有效，能力位有对应内容支撑 |
| 练习 | NOTE/MEASURE/SAFE_START完整，评分标记有效，安全点用全部声部和CC核验 |
| 发布 | 校验与持久提交成功才成为完整曲目 |

块可以切在任意字节处，字段跨块由FPGA读取器处理。FPGA可按块存储、按文件偏移映射读取，无需把整首拼进连续RAM。
