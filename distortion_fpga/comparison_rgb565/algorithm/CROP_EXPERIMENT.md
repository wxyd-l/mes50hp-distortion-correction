# 保持中心与固定裁剪实验

日期：2026-10-07。新代码增加了保持画面中心的裁剪，以及跨多个角度共用一块裁剪区域的离线视频策略。原裁剪策略和上次实验记录保留，默认配置没有替换。

本次全部使用 `examples/camera_demo.json` 的人工内参与 `out/complete_demo/input_synthetic.png`。不是 OV5640 原始帧、真实视场或比赛实板数据。

## 保持中心的结果

同一输入测试 0/10/20/30°，每个角度运行 keep、原 crop-resize、新 crop-center、crop-fixed，共 16 组。所有裁剪模式采用 **0.5 源像素**安全边距；keep 不使用裁剪边距。每组保存图像、有效掩码、精确坐标、LUT、配置和误差报告。

| 角度 | 原裁剪画布保留比例 | 保持中心画布保留比例 | 原裁剪中心偏移 / px | 保持中心中心偏移 / px |
|---|---:|---:|---:|---:|
| 0° | 100.00% | 100.00% | 0.00 | 0.00 |
| 10° | 67.34% | 70.34% | 1.50 | 0.00 |
| 20° | 28.23% | 46.38% | 1.58 | 0.00 |
| 30° | 36.10% | 35.22% | 273.49 | 0.00 |

保留比例定义为 `(roi_width-1)*(roi_height-1)/((W-1)*(H-1))`，分母是旋转后基础画布的像素中心范围，**不是原镜头视场比例**。中心偏移是 ROI 中心到基础画布中心的欧氏距离。所有裁剪结果保持 1280×720 和像素中心宽高比，浮点精确取样的无效像素数均为 0。

20° 时，新策略的画布范围较大，放大倍率由 1.8822 降至 1.4684；30° 时用略少的画布范围换取保持中心。这不保证对所有参数都比原策略保留更多画布。旧实验没有 0.5 像素边距，部分原策略结果会略有不同，不能混用两次数据。

新策略按固定中心和固定宽高比扩大矩形，用积分图检查向外取整后整个矩形内是否存在无效点，不只检查四角；再验证最终全部输出取样坐标。它是保守的离散掩码搜索，非连续映射的全局最优视场求解。

![四种裁剪策略对比](out/crop_experiment/comparison.png)

## 固定裁剪与视频回放

对 **-30/-20/-10/0/10/20/30° 这七个离散变换**取安全掩码交集，生成 `out/crop_experiment/crop_plan.json`。共同 ROI 约为 `[260,146.1611,760,427.6779]`；每次使用相同 ROI，放大倍率 1.6851、画布保留比例 35.22%，中心偏移为 0。

它消除了逐条指令重新选择裁剪窗口引起的中心/倍率变化，代价是 0° 等小角度也使用较小画布。图像内容仍会随旋转改变；这不是完整防抖或平移补偿。

计划绑定相机尺寸、内参与畸变系数的校验码。换相机参数会拒绝；每条实际指令都重新验证完整取样图，不安全时拒绝，不偷偷缩小固定 ROI。只保证已验证的离散变换，**没有保证这些角度之间的所有连续角度安全**。0.5 源像素边距也不是适用于任意镜头和任意 LUT 的误差上界。

已生成三组离线 MJPG AVI，分别使用原裁剪、保持中心和固定裁剪。每组 40 帧，同一人工输入，帧 0/10/20/30 更新到 0/10/20/30°；输入和输出尺寸为 1280×720。播放参数 30 fps 不代表 CPU 或 FPGA 的处理帧率。有损视频只用于看切换效果，数值验收使用 PNG、坐标表与 RGB565 标准。

已独立重新解码输入、三组输出及 `--crop-plan` 命令行输出，全部为 40 帧、720×1280×3；核对记录在 `out/crop_experiment/decoded_video_checks.json`。视频能否在应用内直接播放未验证，可使用本地视频播放器查看。

## 新参数的完整 Verilog 核对

用 30° crop-center 的 LUT 打包同一人工源图，实际运行快速查表版本的整帧渲染器：

- 921,600 个 RGB565 像素及地址与整数标准逐个一致；无效像素 0。
- 仿真渲染周期 40,545,593，包含测试平台随机读等待和写反压，不是实板时序或实时吞吐结果。
- 整数坐标 vs 同一浮点网格最大欧氏误差约 0.002835 px，P99 约 0.002581 px，有效性分歧 0。
- 原导出器的浮点网格 vs 精确完整映射最大误差约 0.032436 px，两项误差不能混为一项。
- 测试包在 `../rtl/out/center30/`，实际结果在 `../rtl/out/package-e48a87abb48a-fast/result.json`；报告保存 RTL 文件校验码。本轮未改动 RTL 源码。

## 复现与使用

项目根目录执行：

```powershell
.\algorithm\run.ps1 crop_experiment.py --video
.\algorithm\run.ps1 pipeline.py image --camera examples/camera_demo.json --input out/complete_demo/input_synthetic.png --view examples/view_center.json --out out/center20
.\algorithm\run.ps1 pipeline.py video --camera examples/camera_demo.json --input out/crop_experiment/input_synthetic.avi --commands out/crop_experiment/video_commands.json --crop-plan out/crop_experiment/crop_plan.json --out out/crop_plan_cli
.\rtl\run.ps1 tools/prepare_package.py --lut ../algorithm/out/crop_experiment/angle30_crop_center --input ../algorithm/out/complete_demo/input_synthetic.png --out out/center30
.\rtl\run.ps1 tools/run_package_sim.py --package out/center30 --fast-map
```

便捷入口会切到对应子目录，所以参数路径相对 algorithm 或 rtl。用真实标定替换示例后，需要重新生成计划、LUT 和标准，并检查边界误差；不要把示例固定 ROI 搬到真实相机上。

## 验证状态

新增 12 项裁剪测试：恒等、中心无效/过小掩码拒绝、内部孔洞、随机掩码穷举尺度对照、正负旋转及源边距、固定 ROI 不变、相机不匹配/危险指令拒绝、非法 ROI、无共同区域、实验文件、视频输出解码帧数和尺寸。软件测试与原有 RTL 回归均通过，仍未进行 PDS 实现或上板。
