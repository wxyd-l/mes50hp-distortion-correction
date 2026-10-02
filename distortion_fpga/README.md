# MES50HP 图像畸变矫正

对应工作区《2026FPGA赛道选题指南-紫光同创.pdf》第二题，目标器件 **PGL50H-6IFBG484**。当前完成的是可复现的离线算法与 RTL 工程，用户尚无硬件；真实标定、视频采集显示、PDS时序和板端实时性能待后续完成。

## 从这里开始

在本目录执行（Python需要NumPy、OpenCV；RTL需要Icarus，见工具说明）：

```powershell
python scripts/verify.py
```

这会重新生成合成测试数据，执行软件测试、数学核测试、独立黄金向量对拍、带随机延迟的整帧测试、缓存和DDR读桥测试，并生成 `reports/latest_verification.json`。缺少仿真器会报错，不会把软件测试冒充RTL通过。仅看软件可明确使用 `--software-only`。

查看合成演示：`build/synthetic_roundtrip/SYNTHETIC_ROUNDTRIP.png`。图中先由独立求逆生成畸变输入，再用定点模型矫正；它证明测试流程和映射方向，不代表真实镜头或上板效果。

## 已有实现

|内容|入口|当前证据|
|---|---|---|
|真实照片标定、参数检查/导出|`software/cli.py`|合成棋盘检测至标定流程测试；等待真实照片|
|浮点/OpenCV/定点三种参考|`software/reference.py`|各畸变系数、1080p坐标精度、边界和溢出测试|
|k1/k2/p1/p2逆映射流水线|`rtl/distortion_mapper.sv`|12级、全局CE、溢出传播、逐位黄金向量对拍|
|RGB888双线性流水线|`rtl/bilinear_rgb.sv`|3级、全部65,536种权重组合及随机像素|
|帧调度与四邻点采样|`rtl/remap_frame_core.sv`|整帧对拍、反压、复位恢复、帧参数锁存|
|32B像素行缓存|`rtl/pixel_read_cache.sv`|同步RAM读取、失效、替换、错误、不覆盖阻塞响应|
|Pango非标准DDR读适配|`rtl/pango_read_bridge.sv`|4字节地址单位、无rready回包缓存、非法地址/协议错误|
|完整读路径联接|`rtl/remap_ddr_read_top.sv`|数学核→缓存→读桥→模拟DDR，整帧黄金像素核对|
|厂商源码整理与接口审计|`scripts/prepare_vendor.py`、`docs/hardware_audit.md`|原始资料SHA256、真实端口和引脚冲突记录|
|缓存访问实验|`software/cache_budget.py`|1080p多种遍历次序的流量估计；不是硬件帧率|

```mermaid
flowchart LR
    A[帧开始锁存参数] --> B[输出像素坐标]
    B --> C[12级畸变映射]
    C --> D[四邻点采样]
    D --> E[32B像素缓存]
    E --> F[Pango DDR读桥]
    F --> G[已有源帧]
    G --> F
    F --> E
    E --> D
    D --> H[3级双线性]
    H --> I[可反压RGB输出]
```

`remap_ddr_read_top`是同一时钟域的读处理集成核，输入帧须已写完并固定在DDR字节地址0。它不包含物理DDR控制器、摄像头捕获、HDMI输出、异步FIFO、帧写入或UART控制，不能直接下载到板卡。`rtl/files.f`列出自研源码，未伪造板级引脚文件。

当前cache为direct-mapped、单未完成请求；流量研究中的4路LRU与输出分块仍是后续优化方案。当前串行四邻点调度每像素需要多个周期，即便数学核支持每周期一个坐标，也不能宣称整机1080p实时。

## 测试与文档

- [验证记录](docs/verification.md)：实际结果、样本数、已发现问题和下一步。
- [题目与验收](docs/requirements.md)：每项要求对应的实现与证据。
- [数值/接口契约](docs/numeric_contract.md)：位宽、舍入、边界、参数原子性、复位。
- [硬件审计](docs/hardware_audit.md)：原例程适配、引脚冲突、DDR协议与流量预算。
- [上板步骤](docs/bringup_checklist.md)：板卡到手后的逐项操作与成功条件。
- [工具准备](docs/tool_setup.md)、[软件命令](software/README.md)。
- [通用综合结构检查](docs/synthesis_check.md)：`python scripts/check_synthesis.py`；完整重跑并包含该检查可用`python scripts/verify.py --synthesis`，不等于PDS器件映射。

## 后续完成顺序

1. 准备MES50HP和实际视频源，先跑厂商DDR及720p视频基线，核对板卡版次与约束。
2. 在PDS检查数学核APM资源、cache是否推断为DRM和时序；约80个18×18等效乘法单元的粗估不能当作实际APM利用率。
3. 增加采集写入、跨时钟FIFO、帧所有权和显示端缓冲，将本项目读核接入完整视频链路。
4. 针对串行采样瓶颈实现并行邻域供数/多未完成读，验证输出分块及缓存策略，再挑战1080p30/60。
5. 用实际镜头的棋盘图生成参数，测直线度、SFR/MTF50、端到端延迟、帧率和资源。
6. 在基础闭环可靠后加入控制通道、动态参数、Gamma；三维透视矫正需要额外齐次变换，当前二维逆仿射不能替代。

原始参考资料保留在项目外层；`vendor/`为本机提取副本，`tools/`为便携验证工具，均不应作为自研代码公开发布。
