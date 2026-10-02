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
```

`demo` 是明确标记的 synthetic 测试，不能用于参赛真实标定结论。实际拍摄应固定镜头、焦距、对焦与传感器分辨率，采集覆盖中心、四角及多种倾斜距离的棋盘照片。参数 columns/rows 是内角点数，square-size 单位自定且保持一致。默认每五张保留一张；至少 8 张训练、2 张留出检测成功。留出图仅估计棋盘位姿，不参与内参训练；低重投影误差不替代直线图卡、清晰度及实物测试。CLI 保存各图 SHA256、逐图误差和角点空间覆盖，固定 k3=0，不开启 rational/fisheye 模型。

JSON `image_size` 为 `[width,height]`，`camera_matrix` 是零 skew 的 3×3 内参，`distortion` 按 `[k1,k2,p1,p2]`。可选 `output_camera_matrix` 控制视场，可选 `output_to_ideal` 是 **输出像素到理想像素** 的逆仿射 2×3 矩阵，默认单位阵。该矩阵应由用户期望的正向旋转/仿射求逆，不能直接把正向矩阵送入。相机三维倾斜一般需要投影模型；本接口只承诺二维仿射。所有输入尺寸必须匹配标定，无隐式缩放。

定点契约：归一化逆仿射 A 为 signed32 Q4.28，先用 signed64 对整数 u/v 乘加，再算术右移 4 成 Q8.24。k1/k2/p1/p2 和中间值为 signed32 Q8.24；每次乘法 signed64 再算术右移 24。r4=mul(r2,r2)，scale=1+mul(k1,r2)+mul(k2,r4)，切向交叉项为 2*mul(p,xy)。fx/fy/cx/cy 为 Q16.16，投影乘法右移 24。每一步 signed32 溢出均检查；导出扫描全幅，发现任何溢出就拒绝，不生成参数。RTL 运行时溢出应黑像素并置 flag。参数量化为最近值（ties to even）；运行时乘法始终算术右移。

源坐标 Q16.16 的小数高 8 位作为插值权重。四个权重乘积之和加 32768 后右移 16，每个越界邻点单独补零，最后行/列整数采样仍然有效。系数允许的数值范围不等于整张图的安全计算范围，以全图验证为准。参数只能在流水线清空后更换。

导出包括 parameters.mem（14 个 signed32 的补码）、parameters.vh、坐标 NPZ、coordinates.mem（每行 source_x[31:0] 拼 source_y[31:0]，按光栅顺序）。demo 另含 input_rgb.mem / expected_rgb.mem（每行 RRGGBB）。JSON 记录系数顺序和来源。没有在 FPGA 使用这些全图坐标表；它们仅供仿真计分。

比较报告把坐标误差与像素误差分开。OpenCV INTER_LINEAR 使用离散权重表，因此与全精度浮点双线性的差异不能自动归因于映射错误。`suggested_valid_roi_xywh` 是验证过的保守矩形建议；裁剪会牺牲视场。插值可避免正向映射留下的空洞，不能恢复相机视场之外未采集的内容。该项目当前没有真实相机照片或硬件测量。
