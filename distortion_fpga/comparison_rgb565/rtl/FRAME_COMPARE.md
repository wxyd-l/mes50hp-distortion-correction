# 导出帧逐像素核对

`tools/compare_frame.py` 用于上板联调：把算法输出缓存直接导出，与同一源帧、同一 LUT、同一定点配置生成的测试包逐像素比较。它不会修正输入，也不把“看着差不多”算作通过。当前工具验证使用人为生成的数据，尚未收到真实 FPGA 导出帧。

## 支持的输入

- memh：每个 RGB565 一行 4 位十六进制，严格按行优先，共 W×H 行；不接受地址指令、额外帧或含糊注释。显式选择 rgb565 或 bgr565。
- raw565：原始 16 bit 像素，显式指定红蓝顺序、字节大小端及可选行 stride。stride 按字节，必须为偶数且不小于 W×2。可含最后一行 padding，也可仅省略最后一行 padding，不能默默忽略额外帧。
- PNG：同尺寸、不透明的 RGB/RGBA 无损图片，按高位重新量化 RGB565。它不是物理总线取样，也不能替代直接帧缓存导出；JPEG 和手机拍显示器不适合逐位验收。

先校验测试包所有输入文件的 SHA256，再读取标准像素和有效掩码。诊断输出必须放在独立目录，不修改标准包或覆盖被比较的输入。

## 命令示例

项目根目录运行，路径参数相对 rtl：

```powershell
.\rtl\run.ps1 tools/compare_frame.py --package out/demo720p --actual captures/output.memh --format memh --pixel-order rgb565 --out out/compare_real
.\rtl\run.ps1 tools/compare_frame.py --package out/demo720p --actual captures/output.raw --format raw565 --pixel-order bgr565 --byte-order big --stride-bytes 2560 --out out/compare_real_raw
```

第二条只是参数用法，字节序与 stride 必须替换成队友确认的实际值，不是 OV5640 或 DDR 工程的默认格式。

完全一致返回退出码 0；像素不一致返回 2，并保留诊断报告。若只想查看报告，可加 `--allow-mismatch`，但报告里的 `exact_match` 不会因此变为 true。非法格式、尺寸或校验失败不按正常图像差异处理。

## 输出和定位

`comparison.json` 给出全图/有效区不一致数量、无效区非黑像素数、差异包围框、首 20 个差异坐标与逻辑地址，以及 R5/G6/B5 各通道的平均/最大代码差。单位为各通道原生量化代码，不是镜头清晰度或标准图像质量分数。

同时生成实际图、标准图、8 倍放大的 RGB8 差异图和二值差异掩码。差异图经过通道位复制展开并放大，仅供查看；逐位判定使用 16 bit 原码。

工具尝试红蓝交换、两字节交换、左右/上下翻转、180° 翻转；只有某个替代操作能减少差异才列为排查提示。对称图案可能让多个假设都改善，不能据此直接认定原因，更不能自动改原始数据掩盖接口错误。

## 已验证的人工故障

对原人工 720P 标准生成六组情况：

| 情况 | 不一致像素 | 结果 |
|---|---:|---|
| 原始标准 memh | 0 | 完全相同 |
| BGR565 大端并带行 stride 正确解码 | 0 | 完全相同 |
| 红蓝交换但按 RGB565 解码 | 89,029 | 红蓝交换提示可恢复一致 |
| 每个字的两字节交换 | 824,236 | 字节交换提示可恢复一致 |
| 左右翻转 | 358,408 | 左右翻转提示可恢复一致 |
| 只改一个像素的 B5 最低位 | 1 | 精确定位一个像素 |

这些文件直接由标准构造，只验证工具本身，不是实板验收。可复现：

```powershell
.\rtl\run.ps1 tools/demo_frame_compare.py --package out/demo720p --out out/frame_compare_demo
```

新增 8 项 Python 测试覆盖格式、大小端、stride、PNG、边界掩码、差异定位、排查提示、校验与输入保护。正式联调还要记录源帧和 LUT 的身份，避免拿错误的帧或配置比较。
