# MES50HP 板级与 DDR 审计

审计日期：2026-10-02。当前无硬件；以下区分资料事实、源码推断和待验证事项。未完成 PDS 综合、布局布线、实际 DDR 校准或 HDMI 上板。离线仿真通过不能替代这些检查。

## 已核对的本地资料

- `../../盘古50K开发板资料/盘古50K开发板/3_Hardware/MES50HP开发板硬件使用手册_1V1.pdf`：正文页 2、7、9、27–31。文件名 1V1，封面写 V1.0/2024-7-19，以实物版次为最终依据。
- `../vendor/10_HDMI_DDR3_OV5640_test/HDMI_DDR3_OV5640_test.pds`：PDS 2022.1 build 99559，Logos PGL50H，-6，FBG484。
- `../vendor/10_HDMI_DDR3_OV5640_test/source/rtl/hdmi_ddr_ov5640_top.v`、`fram_buf.v`、`wr_buf.v`、`wr_cmd_trans.v`、`rd_ctrl.v`、`DDR3_50H/DDR3_50H.v`、`DDR3_50H/DDR3_50H.idf`。
- `../vendor/06_hdmi_loop/src/hdmi_loop.v`、`hdmi_loop.fdc`、`../vendor/07_ddr3_test/`。

`python scripts/prepare_vendor.py` 从原 RAR 提取源码、IP和工程配置，保留原资料，生成 `vendor/manifest.json` 供来源核对；默认查找已安装 UnRAR，也接受 `--unrar`。厂商目录含独立版权与加密 IP，应本地生成，不随自研代码擅自发布。旧 `impl.tcl` 和仿真脚本仅作为资料，运行前检查其绝对路径及输出目录。

## 硬件事实与引脚冲突

| 项目 | 已核对结果 |
|---|---|
| FPGA | PGL50H-6IFBG484；LUT6 42800，DRM 134×18 Kbit = 301.5 KiB，APM 84 |
| DDR3 | 两颗 4 Gbit x16，总计 1 GiB、x32；手册列出多种兼容料号，应按实物选型 |
| DDR峰值 | 400 MHz DDR = 800 MT/s × 4 B = 3.2 GB/s，仅物理理论上限 |
| 晶振 | 系统 50 MHz；另有125 MHz高速接口参考 |
| 视频 | MS7200 HDMI RX / MS7210 HDMI TX，FPGA侧24位RGB+DE/HS/VS/像素时钟 |
| 10例程默认 | OV5640 RGB565，1280×720，顶层注释像素时钟37.125 MHz/30 Hz |

**06回环 FDC 存在明确冲突，不能直接作为本板约束。** 其 `.pds` 声明 FBG484，但 `src/hdmi_loop.fdc` 将 `b_out[7]` 分配 P26；手册表3-7明确 HD_TX_D7=P19，10例程同名输出也是 P19。06可参考 MS72xx 初始化和24位同步接口逻辑。板级工程应从10的DDR/输出约束开始，与手册及最终实物原理图逐项对照；HDMI输入约束按手册表3-6重新核对，不复制06的旧FDC。手册同时把RX/TX复位标为R17，需保持共用复位语义。

已核对的显示信号例：PCLK=M22，VS=W20，HS=Y21，DE=Y22，TX I2C SCL=P17，SDA=P18。这些例子不是完整可下载约束文件。

## DDR 接口不是标准 AXI4

| 信号 | 10例程实际接口 |
|---|---|
| 时钟/复位 | `ref_clk=sys_clk`，`resetn=rstn_out`；输出 `ddrphy_clkin=core_clk`，`ddr_init_done` |
| AW/AR | addr[27:0]、user_ap、user_id[3:0]、len[3:0]、valid/ready |
| 写数据 | wdata[255:0]、wstrb[31:0]；控制器输出 wready、wusero_id、wusero_last |
| 读数据 | rdata[255:0]、rid[3:0]、rlast、rvalid；**没有rready输入** |
| 不存在 | 通用AXI的wvalid、输入wlast、B响应通道、ARSIZE/AWSIZE等 |

不要将通用 AXI master 直接按同名端口接入。`fram_buf`虽声明标准形状的信号，顶层将size/burst/wvalid/rready悬空，B响应绑常量。这是该IP的特定协议，不能作为通用AXI正确性证据。

**地址单位的源码证据：** `wr_buf`一行的`RD_LINE_NUM=H_NUM*PIX_WIDTH/256`，`DDR_ADDR_OFFSET=RD_LINE_NUM*256/32`；`wr_cmd_trans`每个突发后地址增加`(len+1)*8`。因此当前x32配置的addr单位为4字节，一个256位beat覆盖8个地址单位；16beat覆盖512字节、addr增128。抽象字节地址接入时需`ip_addr=byte_addr>>2`，32字节cache line起址要求低5个byte位为0（IP低3位为0）。此推断应再用厂商DDR模型地址花样读写确认，不能推广至x16配置。

`DFI_CLK_PERIOD=10000 ps`是100 MHz控制器时钟配置线索；最终以生成PLL时钟与时序报告确认。该时钟每拍256位的理论吞吐同为3.2 GB/s。

**旧读控制器的局限：** `rd_ctrl.v`在AR握手后固定等待16个周期产生`read_done_p`，并非在RLAST产生；其read_ready未形成真正反压。随机读adapter必须用返回beat计数与RLAST判完成，并在发AR前为全部已发未回数据预留FIFO容量。缓存未命中请求应保持地址/长度稳定直到握手。写端应整突发准备好后才发AW，并严格对照`wr_ctrl`/`wr_cmd_trans`的数据提前量，不能假设wready等同普通AXI握手。

## 推荐接入顺序

1. 先使用项目内与厂商无关的坐标/插值RTL做精确数值、边界、反压测试；抽象请求接口不冒充已实现DDR控制器。
2. 在PDS新建副本工程，选择PGL50H/-6/FBG484，先独立构建07 DDR测试，再构建10摄像头720p30基线。重生成 `DDR3_50H`、`pll`、`wr_fram_buf`、`rd_fram_buf` 对应IP；保存原IDF参数和DDR内建物理约束，避免重复实例化PLL或混入别的板卡引脚。
3. 用06的HDMI逻辑替换摄像头输入时，保留10 DDR及输出侧，按手册核对RX引脚；捕获域到DDR域用异步FIFO，DE用于收像素，VS用于锁存完整帧。复位异步置位、各域同步释放。
4. 输入至少双缓冲，输出若独立DDR帧建议双/三缓冲，分别维护FREE/WRITING/READY/READING所有权。只发布写完的帧，帧切换同时等待未完成读回包，避免撕裂与旧数据串帧。
5. 逆映射四邻域经32B cache line合并读取；返回数据缓存后才给双线性模块。畸变通常具局部性，但90°旋转破坏按行访问，不可只配两行缓存。必要时按输出tile计算，写到输出DDR帧，再顺序显示。
6. 显示端不可反压；DDR回包/计算到像素域用FIFO，测underflow/overflow并提供计数。动态参数仅在SOF原子切换，缓存tag必须包含源frame或切帧清空。
7. 720p基线通过后分别调整1080p时序、PLL、帧步长/地址、OV5640或HDMI输入配置、FIFO与cache；1080p30像素时钟74.25 MHz，60为148.5 MHz（2200×1125总时序）。是否能闭合时序由PDS报告决定。

## 带宽预算与判别实验

RGB565一帧4,147,200 B，RGB888一帧6,220,800 B；双/三帧容量不是DDR瓶颈。1080p60有效像素率124.416 Mpixel/s：

| RGB565流量 | GB/s（十进制） |
|---|---:|
| 采集写一帧 | 0.248832 |
| 四邻域有效像素，未计算缓存复用 | 0.995328 |
| 最坏每邻域浪费一32B beat | 15.925248 |
| 输出帧写+显示帧读（若启用） | 0.497664 |
| 理想每源像素只读一次+采集+输出写读 | 0.995328 |

30fps减半。吞吐预算还要留刷新、行切换、读写转换、仲裁和命令间隔余量。只有峰值以下不能证明可实现；回包延迟尖峰也可能使显示断流。

`software/cache_budget.py`提供真实二维逆映射坐标轨迹上的32B line模拟。测试identity、径向/切向、90°旋转；比较raster与tile输出顺序、cache容量和相联度，同时记录capture/output开销。结果是**离线流量估计，不是DDR时序仿真**。下一步用厂商模型或带有随机延迟/刷新停顿的读服务模型，测试最深未完成请求、完整frame reset及显示FIFO最低水位。

## 厂商仿真与待办

`DDR3_50H/sim/modelsim/sim.tcl`、`sim_file_list.f`和`example_design/bench`均随源码保留，脚本依赖PDS的Pango primitive仿真库，原硬编码路径为`C:/pango/PDS_2022.1/.../arch/vendor/pango/verilog/simulation`。应在副本中改为本机路径，并使用支持该加密库的仿真器。Vivado xsim能用于自研纯RTL数值/协议测试，不等于兼容Pango加密DDR模型。当前未证实厂商全系统仿真可运行。

上板前仍需：确认实物芯片/版次、逐引脚审计、PDS综合/APM/DRM统计、所有时钟与CDC约束、最坏时序收敛、DDR实际可持续读写测试、HDMI真实显示与帧计数验证，以及真实镜头标定数据。无硬件时不应伪造这些完成记录。

## 已运行的流量实验（2026-10-02）

命令：`python -m software.cache_budget --width 1920 --height 1080 --fps 60 --bpp 2 --cache-kib 16 64 --output build/cache_budget_1080p60.json`。

| 场景/输出顺序 | 16 KiB cache，GB/s | 64 KiB cache，GB/s |
|---|---:|---:|
| identity / raster | 0.995328 | 0.995328 |
| identity / 32×32 tile | 1.003853 | 1.003853 |
| k1=-0.3,k2=0.08,p1=.004,p2=-.003 / raster | 1.023882 | 0.968214 |
| 同上 / 32×32 tile | 0.977956 | 0.977937 |
| 90° / raster | 3.124915 | 3.124915 |
| 90° / 32×32 tile | 0.955930 | 0.955930 |

固定参数：RGB565，32B line、4路组相联LRU，fx=fy=1920，主点在图像中心；90°绕中心旋转到同尺寸画布，部分图像因此裁剪。**不同场景有效源覆盖范围不同，不可将跨场景流量高低解释为同等图像覆盖的性能优劣。** 同一90°映射比较raster与tile可判别访问顺序的作用：raster流量已达3.2GB/s物理峰值的97.65%，没有合理刷新/仲裁余量；tile估计降至约0.956GB/s。这支持实现tile/cache原型，尚不能证明tile硬件吞吐成立。16→64KiB未改善旋转raster，说明此轨迹和组映射下只堆容量不够。

小图核验：16×8 RGB565 identity、1KiB cache，raster/tile均8次32B miss，恰好覆盖256B源帧；完整结果见`build/cache_budget_identity_smoke.json`。预算工具不跳过零权重邻域，是保守请求模型；实际内核若跳过可减少访问。


## 与当前RGB888/32位功能基线的区别

上述RGB565表是拟议的带宽优化格式，**不是当前RTL的内存格式，也不是当前RTL测得吞吐**。`remap_frame_core`每像素占4字节（低24位RGB888），每邻域独立请求；现已有`remap_ddr_read_top`在其下连接direct-mapped cache和单beat读桥，但尚无tile或预算模型中的4路LRU。预算工具默认现已设为`--bpp 4`，以避免误读；指定`--bpp 3`表示紧凑RGB888，跨32B边界的像素会计入两条line，硬件尚需对应重组逻辑。

同样1080p60参数，`--bpp 4`的实际离线预算如下，报告位于`build/cache_budget_1080p60_rgb888x32.json`：

| 场景/输出顺序 | 16 KiB cache，GB/s | 64 KiB cache，GB/s |
|---|---:|---:|
| identity / raster | 1.990656 | 1.990656 |
| distortion / raster | 2.189040 | 1.934277 |
| distortion / tile | 1.954902 | 1.951300 |
| rotate90 / raster | 4.012416 | 4.012416 |
| rotate90 / tile | 2.174803 | 1.843430 |

RGB888x32的90°raster在该缓存模型下超过DDR理论峰值，必须改变存取顺序/格式。即使tile降到峰值以下，也不能从本表推出当前核达1080p60：功能核单未完成请求与串行四tap还受每像素周期约束。

预算基于浮点参考坐标，未复现RTL逐级定点量化；在cache line/边界附近可能与实际请求不同。确证时应把RTL导出的坐标/地址轨迹输入同一cache模型。该实验的价值是区分访问顺序与容量两种解释，不是代替RTL/DDR实现审计。

## 已实现的单32B读桥（离线协议验证）

`rtl/pango_read_bridge.sv` 已实现当前x32、1GiB配置的单line读适配。它是可接厂商IP的协议层，**尚未实例化DDR3_50H PHY/IP或完成PDS全工程**，也不是cache或突发性能实现。

| 端口 | 契约 |
|---|---|
| `req_valid/req_ready, req_addr[31:0]` | byte地址；只接受32B对齐、`addr < 0x40000000` |
| `rsp_valid/rsp_ready, rsp_data[255:0]` | 一整条32B line；可无限期反压，直到握手保持稳定 |
| `rsp_error[2:0]` | bit0=未对齐，bit1=越界，bit2=RID/RLAST错误；未对齐/越界不发AR，返回零数据+错误 |
| `protocol_error` | sticky状态；意外/提前/重复回包，或RID/RLAST错误置1，复位清零 |
| `axi_araddr[27:0]` | `req_addr[29:2]`，x32 word地址 |
| `axi_arlen[3:0],axi_arid[3:0]` | 均0；len=0表示一个256bit beat；arid接厂商`axi_aruser_id` |
| `axi_arvalid/axi_arready` | 标准地址握手；AR等待期间地址/len/id稳定 |
| `axi_rdata/axi_rid/axi_rvalid/axi_rlast` | 厂商无rready回包；预期RID=0且RLAST=1；地址接受当拍回包也可捕获 |

一个未完成读，前一完整响应被消费后才接受下一请求。因此发AR时整个response寄存器必为空，不会因响应端反压而丢掉无rready返回。`axi_aruser_ap`在当前例程应沿用绑0；控制器时钟用`ddrphy_clkin`，用户侧请求必须处于同域或另加CDC。

复位是同步低有效，**桥复位本身不取消DDR控制器的外部事务**。必须一起复位/flush IP，或保持桥复位直到旧回包全部drain再放行；不能让旧回包延迟到新事务开始后。收到异常RID/RLAST会返回错误响应避免请求永久悬置；意外回包被丢弃且不覆盖已缓存数据。sticky协议错误后系统应停止新工作、记录现场并共同复位/重新同步，不能依赖固定ID桥恢复任意损坏的返回流。IP完全不返回数据时桥仍等待，外层若需timeout恢复必须同样处理旧事务drain，不能只重置bridge。

验证命令（从工程目录；沿用本机已安装/本地WSL Icarus，不安装全局软件）：

```text
python -c "from scripts.run_hdl import run; print(run('tb_pango_read_bridge','sim/tb_pango_read_bridge.sv',['rtl/pango_read_bridge.sv']))"
```

真实Icarus编译/仿真结果：`PASS pango_read_bridge: 111 transactions`，日志`build/tb_pango_read_bridge.log`。覆盖100组随机合法地址/AR延迟/回包延迟/响应stall、首末合法line、未对齐/越界及组合错误、AR同拍返回、100周期长stall、待发下一请求不得覆盖、RID错误/缺RLAST/两者同时、意外重复/空闲/AR前回包，以及AR未接受/已接受等待/响应已缓存三阶段共同复位。scoreboard检查单未完成请求、AR/响应payload稳定和响应数。模型验证的是已审计端口契约，不是Pango加密DDR模型或物理DDR时序。
