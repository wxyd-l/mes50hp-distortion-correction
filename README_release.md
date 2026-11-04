# M4 列式实时畸变校正 — 实现说明

本仓库根目录下：

| 目录 | 内容 |
|---|---|
| `board_rtl/` | **上板 RTL**（15 个 .v + 5 个窗口表 .hex），签核 bitstream 的源代码 |
| `rtl/` | 仿真 RTL + 全部 testbench |
| `tools/` | 定点黄金模型 `m3_model.mjs`、覆盖率工具、OpenCV 标定链 |
| `verify/` | 五条仿真门槛脚本（路径可移植，`MODELSIM_BIN` 可覆盖 ModelSim 位置） |
| `bitstream/` | 签核版 I 与演示版 J 的 `.sbit` |
| `docs/` | 作品设计报告 PDF、技术总结、开发交接文档 |
| `project_PDS.zip` | 完整 PDS 2022.2 工程（解压得到 `project/`，可直接 `gen_bit_stream`） |

## 关键指标

| 指标 | 数值 |
|---|---|
| 分辨率 / 帧率 | 1280×720 @ 30 fps（pix_clk 37.125 MHz） |
| 单帧处理 | 26.6 ms（37.7 fps），较逐行启停版提升 11.6% |
| 系统时钟 | 50 MHz（DDR3 控制器 100 MHz） |
| 资源 | CLMA 3460/6450（54%）、FF 22%、DRAM 38%、APM 62% |
| 时序 | setup +1.379 ns（0 违约）；hold 2 端点 −15 ps，快角全过 |
| 校正精度 | 4 组角度对拍定点黄金模型，921,600 像素零差异 |

## 验证

```powershell
cd verify
.\run_bisect_m4.ps1 -Rot 15 -Tilt 20 -Pitch 20   # 期望 unequal 0 / 921600
.\run_dual.ps1 ; .\run_arb_sys.ps1 ; .\run_wrback.ps1 ; .\run_board_top.ps1 ; .\run_page_multi.ps1
```

判据：只看 `unequal 0` 不够（`0/0` 表示无可比像素），必须同时满足 `RTL X pixels: 0` 与 `pixels=921600 holes=0`。

## 许可

MIT，见 `LICENSE`。
