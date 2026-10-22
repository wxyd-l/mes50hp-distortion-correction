# 三维姿态与透视坐标链

`software/geometry.py` 将绝对 yaw/pitch/roll 转换为输出相机射线到源相机射线的旋转：

`R_source_from_output = Rz(roll) Ry(yaw) Rx(pitch)`。

角度单位为度，遵循右手旋转；相机坐标为 x 向右、y 向下、z 向前。输出内参为 `Kout`。生成的 `output_to_ideal = Kout R Kout^-1` 为 3×3 矩阵，实际归一化矩阵为 `H = Kout^-1 output_to_ideal = R Kout^-1`。对每个输出像素，RTL 计算：

```
[hx, hy, hz]^T = H [u, v, 1]^T
x = hx / hz
y = hy / hz
r2 = x*x + y*y
s = 1 + k1*r2 + k2*r2*r2
xd = x*s + 2*p1*x*y + p2*(r2 + 2*x*x)
yd = y*s + p1*(r2 + 2*y*y) + 2*p2*x*y
source = [fx*xd + cx, fy*yd + cy]
```

随后按原有逐邻点零边界双线性插值取样。相机纯旋转不依赖场景深度；已知平面也可直接提供逆单应。一般含平移、遮挡和未知深度的三维场景不能用单个 3×3 矩阵完成视点重建。

## 配置与数值语义

- 旧 `output_to_ideal` 2×3 配置仍导出14词，`PROJECTIVE=0` 保留原仿射流水线。
- 3×3 配置导出17词：原14词 `a00,a01,a02,a10,a11,a12,k1,k2,p1,p2,fx,fy,cx,cy` 后追加 `a20,a21,a22`。三行均为 signed Q4.28。
- `PROJECTIVE=1` 选择 `homography_normalizer → distortion_mapper`。64位齐次乘加算术右移4位，得到经过signed32溢出检查的 Q8.24。两个56步无符号恢复除法器计算 `abs(n)<<24 / abs(z)`，再恢复符号；商向零截断。后续Brown–Conrady乘法仍通过算术右移向负无穷截断。
- 商范围为 `[-128,128)`，但这不意味着整个Brown多项式都能接受该范围。各级中间值独立检查；例如 Q8.24 的 `r4` 要求 `r² < sqrt(128)`，径向系数及最终投影还可能进一步缩小范围。`fixed_map` 在导出前检查整个输出网格。
- 通用单应允许负分母，H与−H浮点映射相同。定点输入乘加的算术右移可能造成一个低位差异，独立用例比较其像素坐标误差。软件拒绝视场跨越或触及 `hz=0` 的配置。
- `pose_config` 设置 `projective_positive_depth=true`，拒绝任何后向射线。相应RTL可选 `POSITIVE_DEPTH=1`；纯数学单应使用默认0。零分母、齐次乘加溢出、商溢出及后续多项式溢出产生完整失败token，由帧核输出黑像素并设置 `frame_overflow`。
- 全17词在帧启动时锁存；帧中外部寄存器变化下一帧才生效。`ce=0` 冻结除法及Brown流水线。

## 离线复现与性能含义

```
python -m unittest discover -s tests -p test_geometry.py -v
python scripts/generate_projective_vectors.py
python scripts/run_hdl.py --only projective
python scripts/run_hdl.py --only projective-cached-frame
```

`tests/test_geometry.py` 使用 OpenCV `projectPoints` 的独立三维点投影核验旋转、透视除法及畸变；另用 `initUndistortRectifyMap` 对照全图。测试还故意删除齐次除法并要求出现大于1像素的差异，以排除“只换成3×3容器、仍算仿射”的假实现。

`sim/tb_projective.sv` 检查恢复除法的符号、零分母、极小分母、signed32边界、随机停顿，以及4种映射的逐位坐标。`sim/tb_frame.sv` 加 `PROJECTIVE` 宏检查普通内存帧核；再加 `DDR_CACHE` 检查缓存和Pango读桥集成。第五帧故意注入零分母，检查不访问源内存、每像素仍完成及错误状态。所有配置及图像为 synthetic。

恢复除法正常token的启动间隔为59个启用时钟。它是可综合的完整算术功能基线，并未达到每时钟一个坐标。结合当前逐像素串行访存，不能据此声称1080p30/60。功能仿真周期数与后续PDS频率、资源及硬件视频延迟分别记录；真实标定仍由真实图像产生。
