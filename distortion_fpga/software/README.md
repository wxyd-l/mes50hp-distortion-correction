# 标定与软件参考

直观演示命令：`python -m software.cli roundtrip --output build/synthetic_roundtrip`。输出 `SYNTHETIC_ROUNDTRIP.png` 三栏依次是理想网格、合成畸变输入、定点重建。畸变输入不是对网格直接运行矫正映射：先用 OpenCV `undistortPointsIter` 对每个传感器像素求解其理想源坐标，再采样理想图；随后用独立定点模型矫正。报告记录逆求解器重投影残差。该回环验证方向与实现，两次插值会使细边缘变软，不能证明真实镜头、标定或硬件质量。原 `demo` 的向量格式与内容不受该命令影响。

从项目根目录运行，依赖 Python 3、NumPy、OpenCV（requirements.txt）。所有图像内存数组为 RGB888，PNG 读写通过 OpenCV 转换 BGR/RGB。

```powershell
python -m software.cli demo --output build/synthetic_demo
python -m software.cli roundtrip --output build/synthetic_roundtrip
python -m unittest discover -s tests -p test_reference.py -v
python -m software.cli calibrate --images "captures/*.png" --columns 9 --rows 6 --square-size 25 --output config/camera.json
python -m software.cli export --config config/camera.json --output build/camera_parameters
python -m software.cli compare --config config/camera.json --image captures/independent_grid.png --output build/camera_comparison
python -m software.cli algorithm-demo --output build/algorithm_demo
python -m software.cli pose --config config/camera.json --yaw 8 --pitch -5 --roll 3 --output config/pose.json
python -m software.cli export --config config/pose.json --output build/pose_parameters
python -m software.cli process --config config/pose.json --images "captures/frame_*.png" --mode adaptive --output build/sequence
python -m software.cli process --config config/camera.json --images captures/image.png --mode fixed --gamma 0.8 --output build/single
```

`process`按文件名排序处理帧序列，先对原始RGB执行Gamma，再按定点坐标做双线性取样。每张图输出增强源帧、矫正结果；`pipeline_report.json`记录输入SHA256、使用的Gamma、原始亮度总和／均值和下一帧档位。自适应首帧为恒等Gamma=1，此后的参数来自前帧；单张图片若要立即提亮，用固定模式。可选指数为0.5、0.65、0.8、1、1.25、1.5、2，状态规则见[增强说明](../docs/enhancement.md)。

`algorithm-demo`生成暗光→强光的十帧合成网格，第5帧还改变相机姿态，生成`SYNTHETIC_ALGORITHM_PIPELINE.png`。它复用独立OpenCV逆求解生成的镜头畸变输入，保留每帧控制数据以检查Gamma是否收敛。

`demo` 是明确标记的 synthetic 测试，不能用于参赛真实标定结论。实际拍摄应固定镜头、焦距、对焦与传感器分辨率，采集覆盖中心、四角及多种倾斜距离的棋盘照片。参数 columns/rows 是内角点数，square-size 单位自定且保持一致。默认每五张保留一张；至少 8 张训练、2 张留出检测成功。留出图仅估计棋盘位姿，不参与内参训练；低重投影误差不替代直线图卡、清晰度及实物测试。CLI 保存各图 SHA256、逐图误差和角点空间覆盖，固定 k3=0，不开启 rational/fisheye 模型。

JSON `image_size` 为 `[width,height]`，`camera_matrix` 是零 skew 的 3×3 内参，`distortion` 按 `[k1,k2,p1,p2]`。可选 `output_camera_matrix` 控制视场，`output_to_ideal`是**输出像素到理想像素**的逆变换：2×3为仿射（默认单位阵），3×3为单应。输入是逆向取样矩阵，不能直接使用期望的正向变换。所有输入尺寸必须匹配标定，无隐式缩放。

`pose`从角度生成3×3配置；轴为x向右、y向下、z向前，`R=Rz(roll) Ry(yaw) Rx(pitch)`把输出相机射线转到源相机。姿态替换原有`output_to_ideal`，输出内参保留；设置`projective_positive_depth=true`并检查全幅。`process`也支持`--yaw/--pitch/--roll`直接指定姿态。几何矩阵及其逆的推导、正深度／地平线规则见[透视说明](../docs/projective_geometry.md)。

定点契约：归一化逆仿射 A 为 signed32 Q4.28，先用 signed64 对整数 u/v 乘加，再算术右移 4 成 Q8.24。k1/k2/p1/p2 和中间值为 signed32 Q8.24；每次乘法 signed64 再算术右移 24。r4=mul(r2,r2)，scale=1+mul(k1,r2)+mul(k2,r4)，切向交叉项为 2*mul(p,xy)。fx/fy/cx/cy 为 Q16.16，投影乘法右移 24。每一步 signed32 溢出均检查；导出扫描全幅，发现任何溢出就拒绝，不生成参数。RTL 运行时溢出应黑像素并置 flag。参数量化为最近值（ties to even）；运行时乘法始终算术右移。

源坐标 Q16.16 的小数高 8 位作为插值权重。四个权重乘积之和加 32768 后右移 16，每个越界邻点单独补零，最后行/列整数采样仍然有效。系数允许的数值范围不等于整张图的安全计算范围，以全图验证为准。参数只能在流水线清空后更换。

3×3配置对三行各算Q8.24乘加，再由`trunc_zero((hx<<24)/hz)`和y同式得到归一化坐标；齐次商朝零截断，其后的乘法仍算术右移。软件导出先检查全图的分母与各阶段溢出，硬件每个像素实际执行恢复除法。

导出包括 parameters.mem（仿射14个signed32；齐次在其后追加a20/a21/a22，共17个）、parameters.vh、坐标 NPZ、coordinates.mem（每行 source_x[31:0] 拼 source_y[31:0]，按光栅顺序）。demo 另含 input_rgb.mem / expected_rgb.mem（每行 RRGGBB）。JSON 记录系数顺序和来源。全图坐标表仅供仿真计分；FPGA执行矩阵乘加、除法和畸变多项式。

比较报告把坐标误差与像素误差分开。OpenCV INTER_LINEAR 使用离散权重表，因此与全精度浮点双线性的差异不能自动归因于映射错误。`suggested_valid_roi_xywh` 是验证过的保守矩形建议；裁剪会牺牲视场。插值可避免正向映射留下的空洞，不能恢复相机视场之外未采集的内容。该项目当前没有真实相机照片或硬件测量。

图卡评估使用独立命令，详见[质量测量定义](../docs/quality_metrics.md)：

```powershell
python -m software.quality lines --points captures/line_points.json --output build/line_quality.json
python -m software.quality sfr --image captures/edge.png --roi 160 100 160 192 --orientation vertical --encoding srgb --output build/edge_quality.json
```

直线点集按整条线拟合并报告垂直距离RMS／最大值；SFR需要指定单条斜边ROI和输入编码，报告ESF、LSF、SFR曲线及MTF50。对矫正前后比较时记录各ROI的局部放大倍率；图像像素尺度不同会改变cycles/pixel，不能把Gamma提亮直接当成清晰度提升。
