# FPGA 比赛：畸变矫正算法与 Verilog

本工作目录只开发算法与独立 RTL；桌面的厂商资料和交付归档保持不变。

本目录是 Leo 的算法与 RGB565 对照方案，位于独立分支 `codex/rgb565-mapper-comparison` 的 `distortion_fpga/comparison_rgb565/`。队友的原始实现仍在 `distortion_fpga/rtl/` 等目录，主分支不变。测试命令从本目录运行；生成物、运行环境和交付压缩包不进入版本管理。

- `algorithm/`：真实帧标定、镜头矫正、角度/仿射合成、裁剪、增强、LUT 精度扫描和质量估算。
- `rtl/`：规范化 RGB565 插值、串行/并行坐标查表、双表帧边界切换、源帧取样、整帧写出、独立 Gamma 以及可执行仿真。

先读 `rtl/README.md` 和 `rtl/TEST_REPORT.md`。Verilog 已实际运行，人工 1280×720 帧逐像素比对通过；当前是串行正确性基线，**未达到实时视频要求，也未上板**。

项目根目录可运行：

```powershell
.\algorithm\run.ps1 test
.\rtl\run.ps1 test
```

已完成 143 项 Python 测试（算法 102 项、RTL 参考与交付工具 41 项）、四组原算法 Verilog 回归、两组缓存独立回归和十组公式对照回归。生成物与仿真日志在各自 `out/`，不进源代码版本；重新运行脚本可生成。

旋转与黑边实验见 `algorithm/EXPERIMENT_ROTATION.md`。运行 `./algorithm/run.ps1 rotation_experiment.py` 可重新生成 8 组角度/边界策略对比。

本轮新增保持中心/固定裁剪、16 组对比与三组离线视频，见 `algorithm/CROP_EXPERIMENT.md`；新裁剪 LUT 的 720P 全帧 RTL 核对通过。读取重复性和假设缓存模型见 `algorithm/MEMORY_PROFILE.md`。它们仍使用人工参数，不是实板性能。

新增 `rtl/CACHE_INTERFACE.md` 的通用二路缓存，已核对两组完整 720P 帧和四组末块不足整行的小帧；`rtl/FRAME_COMPARE.md` 可用于上板导出帧验收，`algorithm/CAPTURE_INSPECTION.md` 可检查采集图片。交付包说明见 `DELIVERY_GUIDE.md`。

并行查表已验证单模块持续每拍一个坐标；完整 engine 和缓存仍是单请求基线。下一步是实际突发读写适配及多请求/处理流水化。需要队友确认：实际分辨率/帧率、规范化像素格式、算法时钟、DDR3 用户端口定义、帧缓存地址与所有权。真实标定还需原始棋盘格帧及格子尺寸；没有这些信息时不凭空写死板级配置。

约 120° 镜头仍待确认方向与投影模型，不将其直接换算为真实标定。新增 28 组至 ±60° 的人工旋转检查；1080P 30° 中心裁剪和人工宽视角 720P 60° 裁剪均完成实际 RTL 整帧核对，见 `algorithm/WIDE_ANGLE.md`。

新增 `rtl/formula/` 的直接 Brown 四参数公式分支，数学核派生自队友共享代码；统一 RGB565、采样边界、缓存和人工后端。保留原 Q8 查表版并增加 Q16 对照，公式版完成 720P/1080P 整帧核对。来源、接口与同源比较见 `rtl/MAPPER_COMPARISON.md`，队友原有源码保持不变。公式分支不能代替查表版的三维变换或非零 k3，尚未完成其 PDS 资源和真实 DDR 接入。
