# 畸变矫正比赛：软件算法与验证工具

这份代码与 FPGA 板卡无关，用于算法开发、参数标定和给 RTL 提供参考结果。没有改动归档工程，也没有声称完成硬件实时矫正。

## 范围与约定

- 普通针孔镜头 Brown–Conrady 模型：基础四参数 `[k1,k2,p1,p2]`（二阶径向、切向），也兼容五参数 `[k1,k2,p1,p2,k3]`。不是鱼眼或双目校正。
- 相机内参采用零 skew 矩阵。像素中心为整数坐标，左上角 `(0,0)`，x 向右、y 向下。
- 为每一个**矫正后的输出像素**计算它在**畸变输入图像**中的取样位置。计算方向依据 [OpenCV initUndistortRectifyMap](https://docs.opencv.org/4.x/d9/d0c/group__calib3d.html)。这一步使用正向镜头畸变公式，不对目标坐标再次做去畸变反解。
- 用双线性插值取样。坐标超出 `[0,W-1] × [0,H-1]` 时整个像素置黑，保留有效区域掩码；坐标恰好落在最末行/列时复制该邻居。负坐标不提前截为零。
- 内部使用 float64，图像输出是 RGB uint8，四舍六入、五取偶。它是数值参考，不是现有 RTL 的逐位等价模型。
- 基础库默认输出内参与输入相同，输出尺寸也相同；完整流水线提供合成的相机旋转、图像仿射、有效区域裁剪及保持宽高比的裁剪缩放。
- JSON 里的分辨率必须与真实输入一致。改变摄像头裁剪、缩放、焦距或图像模式后不能盲目复用旧参数。

## 文件

- `undistort.py`：镜头模型、映射生成、像素插值、演示、实验性网格 LUT。
- `calibrate.py`：从原始棋盘格帧得到内参与五参数畸变系数，输出总体及逐帧重投影误差。
- `examples/camera_demo.json`：1280×720 人工参数，**不是 OV5640 的实测标定结果**。
- `tests/test_undistort.py`：已知数值、方向、边界、非整网格、定点溢出、OpenCV 独立比较和人工标定观测测试。
- `geometry.py`：三维纯旋转、二维仿射、合成映射及有效区域裁剪。
- `pipeline.py`：图像处理、视频角度指令回放、Gamma/亮度直方图均衡、LUT 精度扫描、完整演示。
- `quality.py`：给定直线点的误差、棋盘格行列直线度、孤立斜边的开发用 SFR/MTF50 估算。
- `run.ps1`：本机便捷入口，自动选择应用自带 Python 并加载项目内 OpenCV，不安装依赖或修改系统设置。
- `tests/test_pipeline.py`：变换、裁剪、质量估算、视频回放及二阶模型独立验证。
- `rotation_experiment.py`：同一输入下的 0/10/20/30 度与两种黑边策略对比，生成 8 组图像、LUT、掩码和汇总图。
- `EXPERIMENT_ROTATION.md`：这组人工实验的结果、裁剪偏心现象和 RGB565 插值手算说明。
- `crop_experiment.py` 与 `CROP_EXPERIMENT.md`：保持中心/固定裁剪，16 组图像、三组离线视频和新 LUT 整帧 RTL 核对。
- `memory_profile.py` 与 `MEMORY_PROFILE.md`：按整数 LUT 统计四邻居逻辑读请求，评估假设缓存的重复补读，不预测硬件吞吐。
- `inspect_calibration.py` 与 `CAPTURE_INSPECTION.md`：原始标定帧检测/覆盖检查及标注；不拟合相机参数、不删除图片。

## 最快开始

在 `algorithm` 目录运行：

```powershell
.\run.ps1 test
.\run.ps1 demo
```

完整演示在 `out/complete_demo/comparison.png`，每个模式的图像、有效区域、坐标表和报告位于同名子目录。

没有摄像头也能运行。所有演示参数和图片均是人工生成，不能用于正式比赛的真实相机标定验收。

## 运行

在 `algorithm` 目录执行，Python 3.10 或更新版本：

```powershell
python -m pip install -r requirements.txt
python -m unittest discover -s tests -v
python undistort.py demo --camera examples/camera_demo.json --out out/demo
```

基础映射和演示仅依赖 NumPy、Pillow；真实标定与独立对照测试需要 OpenCV。测试发现 OpenCV 不可用会明确跳过对照，不把跳过视为已验证。

本机开发使用应用自带 Python，不修改系统 Python。为独立验证下载的 OpenCV 位于项目根目录 `.runtime`；若使用它，请在 PowerShell 中运行：

```powershell
$taskPython = 'C:\Users\Leo\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$env:PYTHONPATH = (Resolve-Path '..\.runtime').Path
& $taskPython -m unittest discover -s tests -v
& $taskPython undistort.py demo --camera examples/camera_demo.json --out out/demo
```

演示生成：理想直线网格、人工畸变输入、矫正输出、三图对比、有效区域、完整坐标映射、LUT 和误差报告。人工输入通过镜头模型反解生成，仅用于演示，不能替代真实镜头验收。

## 收到队友图片后

```powershell
python calibrate.py --images frames --pattern '*.png' --board 9x6 --square-mm 24 --radial-order 2 --out out/camera_real.json
python pipeline.py image --camera out/camera_real.json --input frames/frame001.png --view examples/view_rotate.json --out out/real
python pipeline.py export --camera out/camera_real.json --view examples/view_rotate.json --step 32 --frac-bits 8 --out out/lut
```

`--board 9x6` 指 **9 列 × 6 行内角点**，对应 10×7 个方格，程序不会再减一。24 mm 只是命令示例，必须替换成实际格子边长。

默认 `--radial-order 2` 在标定拟合时就固定 `k3=0`，不是先拟合三阶再丢掉 k3；需要三阶时显式传 `--radial-order 3`。四参数 JSON 的 model 为 `brown_conrady_4`，五参数为 `brown_conrady_5`。

队友需要提供：

1. 实际镜头类型、摄像头输出分辨率、像素格式、是否做了裁剪/缩放/翻转。
2. 15–25 张直接来自该摄像头的原始清晰棋盘格图片，改变位置、距离和倾角，覆盖中心及四周。必须保证同一输出模式和镜头设置，避免全部正对或集中在中心。
3. 棋盘格内角点数量和实际格子边长；已有标定 JSON 的话一并提供。
4. 几张非标定图片，包含直线边缘，用于单独验收，不只看标定集的重投影误差。
5. 团队最终采用的分辨率/帧率、视场保留策略，以及 FPGA 可接受的坐标格式、表容量、插值方式。指南举 1080P@30fps/60fps 为例，不能据此直接认为 720P 已通过验收。

图片应通过数字采集、帧导出等方式取得，不能用手机拍摄显示器画面来代替原始相机图像。真实帧暂时没有时仍可完成代码、测试、数值精度评估和接口约定。

## 给 FPGA 队友的 LUT 接口（待双方确认）

当前 `grid.memh` 是**实验性新接口**，不能直接替换归档里的 LUT。节点坐标和尺寸必须同时读取 `grid.json`。

- 每个节点一行 16 位十六进制，64 bit：高 32 位是 y，低 32 位是 x，均为有符号二补码定点数；默认 8 位小数，解码时除以 256。
- 行优先，地址 `row * grid_width + col`。输出图的最后一行/列必有节点，末单元通常比 `step` 短，插值分母使用实际节点间距。
- 先对节点做坐标双线性插值，再对源图四像素做像素双线性插值。硬件需独立实现并验证缓存、取样、舍入、饱和、越界与时序。
- 报告包含表大小、全图最大/P99 坐标误差、有效性分歧和有效坐标最大纵向偏移。它不预测最终图像质量，也不保证多少行缓存或每拍吞吐量。
- 当前不是最小面积的坐标格式，网格间距 32 和小数位 8 只是起始配置，应在真实参数下扫描精度/资源后选取。规范化 RGB565 的量化、整数逐位参考及 Verilog 基线现已补在 `../rtl`，真实团队像素接口仍需确认。
- 合成映射导出的表包含角度、裁剪和缩放，`grid.json` 的 `transform` 保存全部配置，不能把它当作裸去畸变表。`output_camera_matrix=null` 表示映射不由单一零-skew 输出 K 描述。
- 当映射穿过相机视线平面、出现无穷/背向射线时，不导出无法表达的坐标。可减少倾角或选择安全裁剪；图像 `--no-lut` 模式仍能将无效射线置黑。

## 任意角度和黑边策略

`examples/view_rotate.json`、`view_tilt.json`、`view_center.json` 可直接修改。支持 `roll,pitch,yaw,angle,scale,shift_x,shift_y,border,crop_safety_px,fixed_roi`。

- 坐标系：x 向右、y 向下、z 朝前，单位为度。源相机射线到目标矫正射线的旋转矩阵为 `Rz(roll) @ Ry(yaw) @ Rx(pitch)`；不要直接把 IMU 欧拉角不经坐标系转换就塞入。
- `angle` 是额外的二维图像顺时针旋转；`scale` > 1 放大；shift 是最终基础画布上的像素平移。完整正向矩阵为 `A @ K @ R @ inv(K)`，取逆后再应用镜头畸变公式获取输入取样坐标。
- 变换和去畸变合成一次取样，不先生成矫正图再重新旋转一次。
- `keep`：保留画布和有效区域掩码，缺失区域黑色；`crop`：取全有效矩形、输出尺寸变小；`crop-resize`：在有效矩形中取原宽高比区域，再映射回原输出尺寸，可能明显损失视场。
- `crop-center`：固定基础画布中心和宽高比，搜索保守全有效 ROI，再回到原输出尺寸；不同角度仍可能放大不同倍率。
- `crop-fixed`：使用预先规划的同一 `fixed_roi`，保持裁剪中心/倍率不变。计划绑定相机参数，每条指令仍须验证；不保证未测试的连续角度，更不是完整防抖。
- `crop_safety_px` 是源像素边距，默认 0，仅影响裁剪；不是通用 LUT 误差上界。新示例使用 0.5，不改变旧示例默认结果。
- 原裁剪先求最大轴对齐有效像素矩形，再做宽高比约束；中心/固定策略有额外约束，所有策略都检查完整输出坐标，不是全局最优视场求解。LUT 近似仍可能改变边界有效性，须检查报告。
- 支持纯相机旋转/图像仿射，不声称恢复平移产生的视差、任意深度场景或图像外信息。特别大的 pitch/yaw 可能没有可用视场，应报错，不输出伪造画面。

## 动态角度：上位机指令回放

```powershell
python pipeline.py video --camera out/camera_real.json --input input.avi --commands examples/angle_commands.json --out out/video
```

可添加 `--crop-plan path/to/crop_plan.json`，让所有指令使用经该相机参数验证的同一 ROI。人工演示和计划生成见 `CROP_EXPERIMENT.md`，不要将人工计划直接用于真实相机。

指令为递增帧号和完整 view 设置，首条 frame 必须是 0。每条 view 是完整替换，不是增量；在帧边界更新并缓存坐标表。这里实现的是离线视频指令回放，不是已接通串口、IMU 或现场 FPGA 的实时上位机。报告的输入 fps 是播放信息，不能当处理帧率。

视频使用有损 MJPG AVI，仅适合演示；质量评估使用无损 PNG。为避免编码器隐式裁剪，视频要求偶数宽高，允许 keep/crop-resize/crop-center/crop-fixed 保持固定输出尺寸，不允许尺寸变化的 crop。

## 预处理与精度扫描

```powershell
python pipeline.py image --camera examples/camera_demo.json --input out/complete_demo/input_synthetic.png --view examples/view_tilt.json --enhance auto-gamma --out out/enhanced
python pipeline.py sweep --camera examples/camera_demo.json --view examples/view_rotate.json --steps 16 32 64 --frac-bits 4 6 8 --out out/sweep
```

增强默认关闭，可选 gamma、auto-gamma、equalize。Gamma 定义为 `255*(in/255)**(1/gamma)`，gamma > 1 提亮；自动 Gamma 按整帧亮度中位数估计，尚未做时域平滑，视频可能闪烁；均衡只调整 YCrCb 亮度。应单独评估噪声、颜色和闪烁，不把增强后的 MTF 变化直接等同于镜头分辨率提高。

扫描会为每组 step/frac_bits 导出 LUT 和汇总 `sweep.json`。比较最大/P99 坐标误差、表大小和有效区域分歧。当前固定为 64 bit/节点，减少小数位不会自动减小存储，真正紧凑位宽还需与 RTL 队友协商。

## 图像质量工具

```powershell
python quality.py chessboard --image out/real/corrected.png --board 9x6 --out out/straightness.json
python quality.py sfr --image test_edge.png --roi 100 80 160 160 --encoding srgb --out out/sfr.json
```

直线度通过每行、每列角点到其拟合直线的正交距离计算，输出 RMS 和最大误差。任意方向直线都不会被误判成弯曲；检测噪声仍会影响结果。也支持 `lines --points points.json`，其内容为 `{"lines": [[[x,y],...], ...]}`。标注点必须来自同一条物理直线。

SFR 工具只接受含一条清晰、近水平/竖直且偏斜 2–10 度的孤立边缘 ROI；至少 32×32，避免多边缘、弯曲、强噪声、饱和。开发用过程为 4 倍过采样 ESF → 求导 LSF → 窗函数 → FFT → 归一化及差分修正，输出 SFR 曲线和 MTF50（cycles/pixel）。参考 [Imatest 斜边方法说明](https://www.imatest.com/imaging/sharpness/)。

**这不是 ISO 12233 合规仪器。** 已做人工高斯模糊边缘解析值回归，但未与标准测试工具对真实图卡交叉验证。编码必须指定 linear/srgb，真实摄像头的响应曲线不一定属于其中之一。MTF50 在 Nyquist 前未交叉时返回 null 而不是 0；比较前后图必须控制输出倍率、ROI、光照、编码和增强设置。

## 比赛要求对应和分工

算法侧已有：真实帧标定工具、二阶映射、重采样、裁剪策略、可变角度/仿射、图像增强、精度扫描、图像质量估算和独立测试。

你交付给队友：真实标定 JSON、带完整变换配置的 LUT、原始测试帧与标准软件输出、直线/清晰度报告、定点精度对比，以及上述接口约定。

算法侧现已补上 `../rtl` 的查表、插值、整帧渲染与配置切换 Verilog 基线及实际仿真。队友实现并验证：视频输入/缓存/输出、配置传输、DDR3 适配、显示时序和跨时钟域；双方共同完成综合、实时吞吐优化、端到端延迟、真实帧率与资源测量。

通用源读缓存已在 `../rtl/src/rgb565_read_cache.v` 实现并完成独立/全帧仿真，仍需真实 DDR 适配。导出帧比较工具和本地交付打包也已补齐，见 `../DELIVERY_GUIDE.md`。

## 验收边界

新增 `polynomial.py` 与 `../rtl/formula/`，可将支持的 Brown 四参数和平面裁剪/仿射导出为直接公式参数，与 Q8/Q16 网格在同一 RGB565 输入上比较。该分支源自队友共享数学核，已有 720P/1080P RTL 坐标和像素核对；不支持非零 k3、pitch/yaw 和鱼眼。来源、复现命令、量化及资源边界见 `../rtl/MAPPER_COMPARISON.md`。

约 120° 镜头信息、28 组大角度人工检查和 1080P 标准帧生成见 `WIDE_ANGLE.md`。新增诊断只检查人工模型的局部映射，不根据视场角选择模型，不自动将示例参数用于真实摄像头。

目前有自动软件测试和人工演示，旋转映射与 OpenCV 独立对照，质量估算有解析回归；Verilog 另有逐位与整帧仿真。尚未验证真实镜头标定、真实图卡标准 SFR、实际 IMU/上位机通信、实板缓存/时序、实时帧率或最终比赛验收。完整验证记录见 `TEST_REPORT.md` 与 `../rtl/TEST_REPORT.md`。
