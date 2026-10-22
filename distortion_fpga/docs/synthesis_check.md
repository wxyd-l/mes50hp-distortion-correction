# 通用 RTL 综合结构检查

2026-10-22 实际运行结果：九个模块及齐次读顶层的参数化配置，共十项均通过 Yosys `check -assert`，检查范围内未发现组合环、多驱动、使用但未驱动的信号，网表中锁存器位数为 0。工具为 Ubuntu 22.04 官方包提供的 **Yosys 0.9，git sha1 1979e0b**。

此记录验证 SystemVerilog 能转换为通用寄存器、组合运算及存储结构。尚未进行 Pango 器件映射、PDS 综合与布局布线、时序分析或板级验证。

## 复现

在工程根目录运行：

```powershell
python scripts/check_synthesis.py
```

本次使用的 Windows Python 完整路径：

```powershell
& 'C:\Users\Lenovo\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' scripts/check_synthesis.py
```

脚本默认检查九个top，再对`remap_ddr_read_top`设置`PROJECTIVE=1,POSITIVE_DEPTH=1`检查齐次分支。它优先使用 PATH 中的 Yosys，否则使用工程内 `tools/yosys-wsl` 的私有工具；Windows 默认 WSL 发行版为 `Ubuntu-22.04`，可通过 `FPGA_WSL_DISTRO` 指定。单独检查或补充依赖的例子：

```powershell
python scripts/check_synthesis.py --top pixel_read_cache
python scripts/check_synthesis.py --top remap_ddr_read_top
```

`--top` 可重复指定，同名 `rtl/<top>.sv` 会自动加入；其他依赖可用 `--rtl rtl/example.sv` 添加。每次检查生成：

- `build/synthesis_<top>.ys`：实际执行的 Yosys 命令。
- `build/synthesis_<top>.log`：原始工具日志。
- `build/synthesis_<top>.json`：通用网表。
- `build/synthesis_results.json`：全部默认 top 的结果、源文件 SHA-256、乘法位宽、寄存器位数及存储端口。使用 `--top` 时报告名带 top 后缀。

本次的通用变换顺序为：

```text
read_verilog -sv <rtl 源文件>
hierarchy -check -top <top>
proc
opt
wreduce
opt
memory_dff
memory_collect
opt_clean
check -assert
stat
write_json <输出路径>
```

`memory_dff` 合并存储读写端口的寄存器，随后 `opt_clean` 删除该变换留下的临时节点。没有执行 `memory_map`、`techmap`、`synth_*` 或 ABC；缓存保持为存储块。仅出现将流水线数组和配置数组转换为寄存器的前端警告，完整原文保存在报告中。

## 实际统计

以下为默认参数 `WIDTH=64`、`HEIGHT=48`、`CACHE_LINES=512` 的结果。计数包含实例化的子模块；不能把各行再次相加作为整个系统数量。

| Top | 通用 `$mul` | 通用 FF 位数 | 未映射存储位数 | 通用单元数 | CHECK 问题 | 锁存器位数 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `distortion_mapper` | 18 | 2,717 | 0 | 293 | 0 | 0 |
| `bilinear_rgb` | 16 | 491 | 0 | 78 | 0 | 0 |
| `remap_frame_core` | 34 | 3,913 | 96 | 589 | 0 | 0 |
| `pixel_read_cache` | 0 | 677 | 140,288 | 3,691 | 0 | 0 |
| `pango_read_bridge` | 0 | 290 | 0 | 48 | 0 | 0 |
| `remap_ddr_read_top`（仿射） | 34 | 4,881 | 140,384 | 4,338 | 0 | 0 |
| `homography_normalizer` | 6 | 723 | 0 | 168 | 0 | 0 |
| `projective_distortion_mapper` | 20 | 3,308 | 0 | 445 | 0 | 0 |
| `gamma_stream` | 0 | 186 | 14,336 | 145 | 0 | 0 |
| `remap_ddr_read_top`（齐次＋正深度） | 36 | 5,568 | 140,384 | 4,499 | 0 | 0 |

FF 位数是通用网表中触发器 `Q` 端口的位数。RAM 端口寄存器已被 `memory_dff` 合并，存储位数单列；这些数字不是 PGL50H 最终 FF、LUT、DRM 或 APM 占用。

映射核的 18 个乘法为 **4 个有符号 32×17→49 位**、**14 个有符号 32×32→64 位**。插值核的 16 个乘法为 **12 个无符号 8×17→25 位**，以及四个权重乘法：8×8、8×9、9×8、9×9。`wreduce` 删除了权重输入中的恒零高位。一个 32×32 运算可能使用多个硬件乘法器，因此 `$mul` 数不能直接作为 APM 数。

齐次归一化有六个矩阵乘法，恢复除法使用移位、比较与减法，无通用`$div`。其Brown–Conrady实例移除四个旧仿射乘法，因此完整映射核20个通用乘法。Gamma的亮度权重、阈值和滞回比较用显式移位加法，没有额外乘法器。Gamma ROM的三个组合读口可能在PDS中复制或映射逻辑，通用位数不表示实际DRM数量。

缓存实际保留了两个通用存储块：

| 存储 | 深度×位宽 | 位数 | 读端口 | 写端口 | 读写时钟使能标记 |
| --- | --- | ---: | ---: | ---: | --- |
| `data_mem` | 512×256 | 131,072 | 1 | 1 | `RD_CLK_ENABLE=1`、`WR_CLK_ENABLE=1` |
| `tag_mem` | 512×18 | 9,216 | 1 | 1 | `RD_CLK_ENABLE=1`、`WR_CLK_ENABLE=1` |

这确认 Yosys 识别了同步读写存储结构。512 个有效位仍属于 FF 统计。`remap_frame_core` 的 `taps` 为 4×24 位的小数组，当前保留为多端口通用存储；器件综合可能将它转换为寄存器。上述存储结构是否映射到 Pango DRM、使用多少块以及能达到什么频率，需要 PDS 验证。

## 数学核延迟与暂停约定

- `distortion_mapper.LATENCY=12`；`bilinear_rgb.LATENCY=3`。
- 输入在 `ce && in_valid` 的上升沿进入第 0 级。若该次有效上升沿编号为 N，输出分别在有效上升沿 N+11、N+2 之后可见；同步下游在下一个有效上升沿消费，因此 testbench 的消费间隔分别计为 12、3。
- `ce=0` 时数据、原始坐标标签、valid 和错误标记全部保持。下游消费必须与该暂停协议一致。
- `rst_n=0` 为同步复位，即使 `ce=0` 也清空 valid。
- 映射配置必须在整条流水线占用期间保持不变。`out_valid` 表示完成 token，包含计算失败的 token；此时 `out_overflow=1` 且坐标清零，帧控制器消费该 token 并生成黑色像素。

## 本地工具准备记录

本次仅下载、解压官方 Ubuntu 软件包到工程 `tools/`，未全局安装。若需要重建，在 WSL 内运行：

```bash
cd /mnt/e/code/fpga/distortion_fpga
mkdir -p tools/yosys-wsl/packages
cd tools/yosys-wsl/packages
apt-get download yosys=0.9-2 libtcl8.6=8.6.12+dfsg-1build1
dpkg-deb -x yosys_0.9-2_amd64.deb ..
dpkg-deb -x libtcl8.6_8.6.12+dfsg-1build1_amd64.deb ..
cd ../../..
env LD_LIBRARY_PATH=/mnt/e/code/fpga/distortion_fpga/tools/yosys-wsl/usr/lib/x86_64-linux-gnu \
    tools/yosys-wsl/usr/bin/yosys -V
```

`LD_LIBRARY_PATH` 仅设置在工具子进程中；没有修改系统动态库配置。实际下载包 SHA-256：

```text
yosys_0.9-2_amd64.deb
b9f27c0a999753ecc12efa31ebdf97de5a0ca4f970780ddf580b8668a47e8a20

libtcl8.6_8.6.12+dfsg-1build1_amd64.deb
5232b051f9dcd567648ab3061848329ef15cc3a8cb1e66732be80f102dad293c
```
