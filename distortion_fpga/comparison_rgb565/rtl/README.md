# 畸变矫正 Verilog：算法侧正确性基线

现在已有可运行的 Verilog，不再只有软件预览。已验证 RGB565 双线性插值、坐标网格插值、越界补黑、双表配置、帧边界切换、整帧写出，以及独立的 Gamma 模块。

这是多周期、串行访存的正确性基线，**不是达到实时帧率的成品工程**。源码按可综合逻辑编写；尚未经过 PDS 综合、布局布线或实板验证。厂商摄像头/DDR3/HDMI 工程没有改动。

## 最快运行

在项目根目录运行：

```powershell
.\algorithm\run.ps1 test
.\rtl\run.ps1 test
```

第一条检查 102 个软件测试；第二条检查 41 个定点参考、导出帧比较、公式对照和交付工具测试，再用本机 ModelSim 仿真四组原算法组合、并行查表单独测试、两组缓存独立测试及十组公式分支测试。需要 NumPy、Pillow 和可用的 ModelSim；辅助脚本选择本机应用自带 Python，否则使用 PATH 中的 Python，不自动安装软件。

整帧 720P 演示：

```powershell
.\algorithm\run.ps1 demo
.\rtl\run.ps1 tools/prepare_package.py --lut ../algorithm/out/complete_demo/rotate_keep --input ../algorithm/out/complete_demo/input_synthetic.png --out out/demo720p
.\rtl\run.ps1 tools/run_package_sim.py --package out/demo720p
```

仿真逐像素比对 921,600 个输出，不只是生成图片。单个完整帧仿真可能需要一分钟左右。源图和镜头参数都是人工示例，不是摄像头实测。

也可以运行 `./rtl/run.ps1 full`，自动重新生成演示和测试包，再检查串行与快速查表两种模式的完整帧及全部小规模回归；通常需要两分钟左右。

## 模块分工

| 文件 | 作用 | 时序特点 |
|---|---|---|
| `src/bilinear_signed.v` | 四个有符号值的双线性插值 | 三个 CE 有效时钟沿；可每拍接收一组 |
| `src/bilinear_rgb565.v` | 分开插值 R5/G6/B5 三个通道 | 同上；不能把整个 16 bit 色值当数字插值 |
| `src/stream_delay.v` | 延迟 valid、坐标、行帧标记组成的 token | 与像素使用同一 CE；不产生显示时序 |
| `src/map_lut.v` | 两套坐标表，顺序装载、完整提交 | 单个同步读口，独立配置写口 |
| `src/grid_mapper.v` | 输出像素坐标 → 输入 Q 格式坐标 | 串行读四节点，valid/ready 支持等待 |
| `src/grid_mapper_fast.v` | 同一数值约定的并行坐标查表 | 四个同步读口，五级全局停顿流水，持续 ready 时每拍一坐标 |
| `src/undistort_engine.v` | 查坐标、读四像素、插值、补黑 | 一次只处理一个像素，一次一个未完成读请求 |
| `src/remap_frame_writer.v` | 自动遍历输出坐标，写出完整一帧 | 不产生 HDMI DE/HS/VS；输出写口支持等待 |
| `src/gamma_rgb565.v` | 静态逐通道 Gamma，携带自定义元数据 | 一个 CE 有效时钟沿；独立模块，主渲染器默认未连接 |
| `src/rgb565_read_cache.v` | 通用二路只读块缓存，按帧清有效位 | 单请求阻塞式；命中同步读像素，未命中接收完整有序块 |

`sim/` 都是测试平台，不加入 PDS 综合文件列表。`tools/reference.py` 是整数逐位参考；原来的 RGB8 浮点预览不是 RTL 逐位标准。

engine/frame_writer 设置 `USE_FAST_MAP=1` 可选择已验证的并行查表；默认 0 保留低表存储基线。两种模式使用相同 LUT 和逐位标准。并行版用四份双缓冲表换取四个读口，逻辑表存储为基线的四倍；720P 示例共 62,976 字节。这个数字不是综合后的 BRAM 用量，也未保证能在目标频率收敛。

可以对同一测试包验证快速查表：

```powershell
.\rtl\run.ps1 tools/run_package_sim.py --package out/demo720p --fast-map
```

只有坐标查表模块支持连续每拍接收一个坐标，完整 engine 仍一次处理一个像素、串行读四邻居。开启 USE_FAST_MAP 不等于整机已达到每拍一像素。

## 数值约定

默认源与目标尺寸 1280×720，网格间距 32，坐标小数位 8，坐标插值权重小数位 16。参数可改，但源、目标尺寸至少为 2，网格间距必须为 2 的整数次幂，末节点必须是最终像素。

- 节点 64 bit：`[63:32]` 是 signed int32 y，`[31:0]` 是 signed int32 x。默认除以 256 得到像素坐标；行优先。
- 1280×720、step=32 共 41×24=984 节点，每表 7,872 字节，双表 15,744 字节。
- `COORD_FRAC` 与 `WEIGHT_FRAC` 是不同参数。末单元通常不足 32，权重除以实际宽/高，不能仍然除以 32。
- 节点的离线量化是 NumPy 五取偶；运行时两次插值分别只在最终结果舍入一次，最近取整，恰好半值时朝正无穷，例如 -0.5 → 0。不要拿浮点 RGB8 图片直接逐位比对。
- 默认坐标权重 16 bit，是为了控制短末单元的分数近似；也实际仿真了 8 bit 版本。两者允许产生不同边界结果，测试文件不可混用。
- 输入颜色必须已经规范化为 `R[15:11], G[10:5], B[4:0]`。资料中的供应商摄像头例程设置 BGR565，再在顶层交换红蓝；算法接在规范化后的数据上。实际团队工程还要核对，不能再次交换两次。
- 取样坐标在 `[0,SRC_WIDTH-1]×[0,SRC_HEIGHT-1]` 外时，整像素黑，sample_valid=0，且不请求源存储器；边界恰好落在最终行/列时复制该邻居。
- 地址默认 24 bit，按 **RGB565 像素** 计数，不是字节；配置地址 16 bit，最多 65,536 节点。辅助打包工具拒绝不支持的参数。

## LUT 装载和角度更新

所有端口属于 `clk`，复位是同步、低有效。跨时钟域由适配层处理。

1. 复位后 `active_ready=0`，不能处理图像。即使设置 `INIT_FILE`，也必须完整装载；软复位不会恢复 RAM 初值，不能误用被部分覆盖的表。
2. `cfg_begin` 单独脉冲一拍，开启非活动表装载。
3. 仅在 `cfg_ready=1` 时发送 `cfg_we`。地址必须依次 0、1、…、NODES-1，每拍写一个 64 bit 节点。
4. 最后一次写入后的下一拍单独发送 `cfg_commit`。只有整表且无错误才成为 `pending`。
5. 完整新表尚未切换时，旧表继续使用。不可同时 begin/write/commit，也不要在切换拍发送配置操作；错误写法会设置 `cfg_error`。合法的新 `cfg_begin` 清除它。
6. 独立 engine 只在 `frame_ready=1` 时接收 `frame_start`，新表此时生效。调用者必须保证它是真正帧边界，不能在每个像素之间触发。`remap_frame_writer` 已在每次 start 后自动触发这一边界。
7. 有 pending 时不能继续覆盖它。无 pending 的帧边界继续使用现有活动表。

动态角度在本版中的含义是：上位机生成新的合成映射表，完整装载，在下一输出帧边界切换。不是 FPGA 内部已经实时计算 IMU 姿态；串口命令、传输带宽和生成表延迟还未接通/测量。

## 源存储器读接口

只有 `valid && ready` 的时钟沿表示传输完成；等待时发送方必须保持 valid 和数据不变。

- `mem_req_valid/ready/addr`：发出一个逻辑像素读请求。
- `mem_rsp_valid/ready/data`：返回规范化的 RGB565。响应最早在请求接受后的下一拍，必须保持到被接受，不可只脉冲一拍后丢弃。
- 一次至多一个未完成读请求，没有 AXI ID、突发长度或物理 DDR 控制命令。有效取样串行读四个邻居，边界重复地址也会读四次。
- 紧密存储的字节地址可由适配层计算 `source_base + 2*logical_pixel_address`。带行 padding 时适配层必须按实际 stride 换算。
- 源帧必须保持不变直到输出 done。复位时存储器适配层也要取消/排空旧请求，不能把上帧响应送进新事务。

这里是接口规范，不是已经实现 DDR3 适配器。现有 DDR3 突发接口不能直接接这几根线。

## 完整输出与 HDMI 的接入位置

第一版建议走完整帧的回写方式：摄像头采集 → 规范化 RGB565 的源帧缓存 → 此模块随机取样 → 矫正后目标帧缓存 → 原 HDMI 显示读取。

`remap_frame_writer` 的 `start && start_ready` 开始一帧；`wr_valid && wr_ready` 接受输出像素，地址从 0 到 OUT_WIDTH×OUT_HEIGHT-1，最后一次写接受后 `done` 脉冲一拍。只有全部实际写完成的输出帧才能交给显示读取，不能把“写入适配器队列”误当成 DDR 已可见。

具体顶层代码的插入点是**源 RGB565 帧缓存之后，HDMI 读取目标缓存之前**，不是直接塞在 DVP 两字节拼接器和固定像素时钟显示输出之间。默认模块不能承受无等待的实时视频流。

队友需要提供源帧所有权管理、输出显示换帧、读写仲裁、源/目标独立缓冲、跨时钟域及 DDR 可见性保证。处理一帧期间采集不能覆盖它；仅说“乒乓缓存”还不够，必须明确渲染落后时的丢帧和缓冲占用策略。本基线处理慢，最终要优化而不是用缓冲掩盖吞吐不足。

## Gamma 模块

```powershell
.\rtl\run.ps1 tools/generate_gamma.py --gamma 1.8 --out out/gamma18
```

将两个 memh 路径设为模块的 LUT5_FILE/LUT6_FILE。公式为 `max*(in/max)**(1/gamma)`，每通道在其 5/6 bit 范围中取整，gamma>1 提亮。与先做 RGB8 Gamma 再量化不保证逐位相同。

可放在规范化源像素写入缓存前，或放在完成插值后；两者的数值不等价。质量评估先保持关闭。必须同步延迟坐标/有效性/行帧标签，并在停顿时使用统一 CE；不要仅延迟 RGB。本模块没有独立 out_ready，集成方应提供输出槽或统一流水线停顿。

ROM 默认恒等，生成的 Gamma 表保留 0 和最大值，黑边不被提亮；启停在帧边界决定。文件初始化能否被目标 PDS 正确推断必须通过综合和实现检查。未做自动 Gamma、直方图均衡硬件，也未把该模块默认连接进渲染器。

## 收到真实帧后交付给队友

先用 `algorithm/calibrate.py` 标定，再用 `pipeline.py export` 导出表。然后执行：

```powershell
.\rtl\run.ps1 tools/prepare_package.py --lut ../algorithm/out/lut --input ../algorithm/frames/frame001.png --out out/real_frame001
.\rtl\run.ps1 tools/run_package_sim.py --package out/real_frame001
```

打包目录包含原表/元数据、source_rgb565.memh、expected_rgb565.memh、expected_valid.memh、预览 PNG、参数头和 SHA256 校验报告。脚本严格检查尺寸和节点，不默默缩放或猜颜色格式。

报告分别列出“RTL 整数插值 vs 同一浮点网格”的误差，以及原导出器记录的“浮点网格 vs 完整映射”的误差，不能把前者当成总镜头校正误差。PNG 是查看图，memh 才是逐位验收标准。工具不判断图片是否真正来自摄像头，真实数据来源需团队确认。

## 为什么下一步是性能优化而非直接上比赛

720P 人工测试帧实际仿真：串行查表需要 44,514,534 个算法时钟周期，并行查表需要 37,140,721 个，减少约 16.6%，均含测试平台随机读写等待。两者输出逐位相同。即使假设能实现 100 MHz，也只分别约 2.25 和 2.69 帧/秒；这只是周期换算，**不是实测时钟或帧率**，且不能移植成真实 DDR 延迟预测。

720P30 每秒要产出 27,648,000 个有效像素。坐标并行流水已经实现，接下来需源数据行/块缓存、突发访存及多请求流水；任意旋转的访存范围还必须用实际 LUT 测量。不能只把时钟提高或直接宣称“插值流水线每拍一像素”就代表整机实时。

在真实 DDR 接口和可用带宽确定前，保留这份基线做逐位回归标准。验证记录见 `TEST_REPORT.md`。

算法侧已新增 `../algorithm/memory_profile.py`，可对导出 LUT 分析逻辑源读和假设块缓存。两组人工参数的结果及过读风险见 `../algorithm/MEMORY_PROFILE.md`。该工具是软件访问模型；对应缓存 RTL 已另行实现，真实 DDR 适配仍未完成，不将命中率当作帧率。

访问模型之后已实现独立缓存 RTL 并验证两组 720P 完整帧；真实 DDR 适配仍未实现，详情见 `CACHE_INTERFACE.md`。可运行 `./rtl/run.ps1 tools/run_package_sim.py --package out/demo720p --fast-map --cache`，或 `tools/small_cache_demo.py` 覆盖末块 padding。原 engine 不默认插入缓存，接线见缓存专用测试平台。

## 公式计算对照分支

`formula/brown_mapper_pipeline.sv` 复用队友共享的 Brown 四参数数学核；`formula/brown_frame_writer.sv` 接入本项目 RGB565 采样和写出接口。原十个处理模块未改动，新增两个可独立选择的公式模块。720P 和 1080P 公式帧已逐个核对坐标、像素、地址通过；同源 Q8/Q16 查表对照和复现入口见 `MAPPER_COMPARISON.md`。公式分支是平面仿射版本，不支持非零 k3、pitch/yaw 或鱼眼，不自动替换原查表路径。

上板导出帧核对见 `FRAME_COMPARE.md`，本地源码 ZIP 的构建/校验见 `../DELIVERY_GUIDE.md`。
