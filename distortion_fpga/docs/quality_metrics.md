# 直线度与斜边 SFR 测量

赛题第二题原文在 PDF 物理第 13 页要求用测试图卡评估 MTF50/SFR 与直线度，没有给出数值合格线。`software/quality.py` 提供两个独立测量入口；它们接收用户选定的点集或单边 ROI，输出可复算的 JSON。这里的数值验证使用明确标记的合成数据。

## 整条直线的正交残差

每个 `lines` 条目表示图卡上的**一整条物理直线**。对该条目全部点等权做 TLS：以点集均值为中心，对中心化坐标做 SVD，最小奇异值对应的单位向量是法向量 `n`。每点有符号垂距为 `r_i = n · (p_i − mean(p))`。

- `rms_perpendicular_px = sqrt(mean(r_i²))`。
- `max_abs_perpendicular_px = max(abs(r_i))`。
- `span_px` 是点集沿拟合直线方向的投影跨度。
- `line_abc` 给出 `a*x+b*y+c=0`，其中 `a²+b²=1`。

输出保留所有输入点及逐点残差。程序不剔除离群点、不自动分段；弯曲线段不能通过拆短来降低报告残差。等权 RMS 会受点密度影响，因此矫正前后应沿同一条物理直线、相近位置和间距取点，同时保留跨度；短线和长线的 RMS 不直接混成一个几何准确度结论。

点集格式示例（人工格式示例）：

```json
{
  "provenance": {"kind": "synthetic_format_example"},
  "lines": [
    {"id": "row_1", "points": [[10, 20], [50, 20.3], [90, 20.4], [130, 20]]}
  ]
}
```

在 `distortion_fpga/` 目录执行：

```powershell
python -m software.quality lines --points captures/grid_points.json --output build/quality/lines.json
```

## 指定单条斜边的 SFR

`--roi X Y WIDTH HEIGHT` 是输入图片中的整数矩形，零基坐标，像素中心位于整数坐标。`vertical` 表示接近竖直的边，`horizontal` 表示接近水平的边。水平边仅交换数组轴，不插值旋转图片。

```powershell
python -m software.quality sfr --image captures/chart.png --roi 160 100 160 192 --orientation vertical --encoding srgb --output build/quality/edge.json
```

必须显式选择图像编码：

|参数|线性化定义|
|---|---|
|`--encoding linear`|整数码值除以 255 或 65535 后直接使用|
|`--encoding srgb`|标准分段 sRGB 解码：低于 0.04045 除以 12.92，否则 `((v+0.055)/1.055)^2.4`|
|`--encoding power --gamma 2.2`|`linear = normalized_code ** gamma`；指数由用户提供|

CLI 接受 8/16 位灰度或 RGB 图片。RGB 每通道先线性化，再按 `0.2126 R + 0.7152 G + 0.0722 B` 得到分析通道；灰度不经过颜色权重。`srgb` 或幂函数只对应所声明的编码，无法替代相机未知的 OECF。API `slanted_edge_sfr()` 直接接收已线性化的二维 NumPy 数组。

边定位、投影、差分和频谱归一化采用边梯度法。其测量偏差来自边方向估计、离散差分和噪声，见 Burns 的[原始论文全文，2000，pp.135–138](https://www.imaging.org/common/uploaded%20files/pdfs/Papers/2000/PICS-0-81/1621.pdf)。本实现的明确计算定义如下：

1. 对每行求三点中央差分，用两次 Hamming 加权梯度质心估计边位置，再拟合一条 `x=a*y+b` 直线。保留逐行位置与此直线的垂距。所有行使用同一条拟合直线投影。
2. 对每个原始像素计算边法线距离 `d=(x−a*y−b)/sqrt(1+a²)`，按 `h=0.25 px` 分箱并求均值，形成四倍采样 ESF。这一距离定义包含斜边角度的几何尺度修正。
3. 使用全部行共同覆盖的对称距离范围 `[-R,R]`，不补空 bin。LSF 为 `(ESF[j+1]−ESF[j−1])/(2h)`，亮暗反向时仅统一 LSF 符号。
4. LSF 使用 Tukey `alpha=0.5` 窗：中央一半长度权重为 1，外侧余弦渐消。渐消区必须从平台开始，避免把宽 LSF 截窄。FFT 至少补零到 4096 点；补零只加密频率插值，不增加实测分辨能力。
5. 频谱模除以零频值后，乘 `1/sinc(2fh)` 补偿中央差分，再乘 `1/sinc(fh)` 补偿矩形分箱；这里 `sinc(t)=sin(pi*t)/(pi*t)`。第一项在 `f=0.5 cyc/px` 时是 `1.1107207`，与[Imatest 原始差分传递函数推导](https://www.imatest.com/2015/04/lsf-correction-factor-for-slanted-edge-mtf-measurements/)一致。第二项是均匀分箱近似，角度/相位扫测检验其误差；相机像素面积、镜头、ISP 和图卡本身的模糊仍保留在响应中。
6. `mtf50_cycles_per_pixel` 是归一化 SFR 首次向下越过 0.5 的线性插值频率，以零频值为基准，不是以曲线峰值为基准。单位是**待分析图片像素**的倒数，方向为边法线。

JSON 的 `curves` 保存 ESF 距离、线性 ESF、每 bin 样本数、LSF、窗、加窗 LSF、频率、校正前后 SFR 及两个补偿因子，直接读取这些数组即可绘图。曲线输出到 0.5 cyc/px；可接受的 MTF50 上限为 0.4 cyc/px。超过上限或没有交点时，`status=not_measurable`、MTF50 为 `null`，仍保存曲线，命令退出码为 2。

## 可测条件与结果解释

输入是均匀照明、两侧有平台的单条直边 ROI。拟合边距所选轴须为 2–10°，沿整段至少横移 4 px；ROI 至少 32×32 px，且每行两侧共同支持范围至少各 12 px。每个 ESF bin 都须有实际样本。软件采用以下两项数值可测条件：

- 逐行定位的垂距 RMS ≤0.1 px。超过时可能是曲边或定位噪声，程序拒绝输出 MTF50；它不通过逐行平移把曲边自动拉直。
- 渐消区起点附近的 ESF 均值相对平台偏离 ≤边对比度的 1%。过宽的边需要更宽 ROI；不能用固定窗把模糊裁成更高的清晰度。

条件不满足时写 `status=failed` 与具体原因，退出码为 2。这些是本估计器的可测条件，赛题没有发布这些阈值。没有设定与 ROI 无关的低频下限：更低的 MTF50 需要更宽的平台与支持范围。

真实比较需使用同一物理图卡、相同曝光/对焦/光照，并记录编码和 ROI。选择没有黑边、饱和、图卡转角或多条边混入的区域。更换 JPEG 压缩、锐化、降噪或 gamma 设置会改变 SFR，必须随结果记录。矫正改变局部放大倍率，所以矫正前后同一场景位置的 `cyc/px` 变化同时含局部尺度变化；应同时报告图卡尺度或局部映射倍率，不能仅凭数值上升归因于锐度改善。图卡边缘质量未经测量时，这里得到的是图卡与成像/处理链路共同的边缘 SFR。

直线度与 SFR 各自回答不同问题：完整线条的几何弯曲量；指定局部直边的频率响应。曲边无法通过 SFR 可测条件时，应先用完整点集残差检验几何矫正，再在满足条件的局部直边处测清晰度。

## 独立软件验证

```powershell
python -m unittest discover -s tests -p test_quality.py -v
```

11 项测试包括：

|验证|独立基准与通过条件|
|---|---|
|TLS 及坐标旋转|已知正交残差；旋转、平移、竖线仍得到相同 RMS/最大值|
|整条弯曲线|101 个抛物线点；结果等于整条线的解析残差，没有分段|
|Gaussian 斜边|在 1/256 px 网格上卷积阶跃与 Gaussian，再在像素中心取样；`MTF(f)=exp(−2*pi²*sigma²*f²)`，`MTF50=sqrt(ln(2))/(sqrt(2)*pi*sigma)`|
|采样角度和相位|6 个 sigma（0.48、0.5、0.75、1.5、3、5 px）×8 个角度×4 个相位，共 192 组；包含斜率 1/16、1/12、1/8 的周期采样。MTF50 相对误差 <2%；在 `f≤min(0.4,2*MTF50)` 内 SFR 绝对误差 <0.02|
|像素面积效应|每像素 8×8 次数值积分；解析基准额外乘法线两个分量对应的矩形孔径 sinc，MTF50 相对误差 <2%|
|量化与噪声|8 位量化、固定随机种子、1 码值标准差白噪声、3 个 sigma，MTF50 相对误差 <3%|
|窗口和失败行为|过宽边在窄 ROI 拒绝，扩大 ROI 后 sigma=12 px 的解析 MTF50 对照误差 <2%；曲边拒绝；超出频带的锐边输出 null|
|实际文件链路|16 位 sRGB PNG 解码、指定 ROI、水平/反向边、JSON 曲线输出|

这些数值是上述合成条件下的测试容差，不是任意相机照片的误差保证；真实图卡的重复测量分散度需由实际采集数据估计。
