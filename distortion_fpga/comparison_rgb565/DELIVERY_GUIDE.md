# 算法与 Verilog 交付说明

本地交付包包含算法、测试、十个原处理 RTL 模块、两个公式对照模块、仿真工具、接口说明及经当前源码校验的仿真结果，可交给负责板卡的队友继续联调。公式数学核派生自团队私有共享代码，来源见 `rtl/formula/ORIGIN.md`，不构成公开发布授权。它不是可直接烧录的 PDS 工程，不包含厂商 IP、引脚约束、运行软件、真实相机标定或已接通的 DDR3 适配器。

## 推荐阅读顺序

1. `rtl/TEAM_INTERFACE.md`：确认源/目标帧所有权、像素格式、DDR 接口、时钟与换帧。
2. `rtl/README.md`：原算法基线的数值、LUT 和帧写口约定。
3. `rtl/CACHE_INTERFACE.md`：新增缓存的接线、块响应、清缓存与联合复位规则。
4. `rtl/FRAME_COMPARE.md`：输出帧直接导回电脑后逐像素核对。
5. `algorithm/CAPTURE_INSPECTION.md`：收到原始棋盘格帧后的检查与正式标定流程。

算法用户先看根 README、裁剪实验和采集检查；板级队友不要把仿真内存模块加入综合列表。

## 验证与环境

当前 143 项 Python 测试通过，无跳过；四组原算法 RTL 回归、两组缓存独立回归、十组公式回归及多组 720P/1080P 完整帧已实际仿真通过。新增大角度及公式/查表统一对照见 `algorithm/WIDE_ANGLE.md`、`rtl/MAPPER_COMPARISON.md` 和 `rtl/TEST_REPORT.md`。全部仍是人工数据，未完成 PDS 实现、真实镜头或实板性能验收。

解压后需要 Python、NumPy、Pillow；采集检查/标定/独立对照需要 OpenCV，实际 RTL 仿真需要 ModelSim 命令可用。便捷脚本优先使用本机应用自带 Python，否则用 PATH，不安装依赖。迁移电脑时请自行准备环境，不把本机 `.runtime` 当交付依赖。

```powershell
.\algorithm\run.ps1 test
.\rtl\run.ps1 test
```

更新的宽视角交付 ZIP 附带 `reference_package/` 的人工 1080P LUT、源帧、逐位标准和参数；早期 ZIP 附的是 720P，具体尺寸以包内 `package.json` 为准。可直接检查：

```powershell
.\rtl\run.ps1 tools/run_package_sim.py --package ../reference_package --fast-map --cache
```

其相机参数仅为示例，禁止当真实标定。档案中的 JSON 可能保留生成机器的路径用于来源记录，程序使用包内文件，不要求这些旧绝对路径存在。

公式对照源码及当前仿真报告随新版包提供，公式标准包不自动收集；可按 `rtl/MAPPER_COMPARISON.md` 重新生成三套同源包并仿真。默认 `rtl/run.ps1 test` 包含新增十组小帧公式测试。

## 打包与校验

`build_delivery.py` 只收集明确范围的源码、文档、示例、测试与可选标准包，排除运行库、厂商工程和原始采集目录。已过期或源码校验不匹配的仿真报告不纳入当前结果。ZIP 内 `delivery_manifest.json` 记录每个文件的 SHA256 和大小，构建完成后逐个重新读取校验。

```powershell
.\rtl\run.ps1 tools/build_delivery.py --package out/demo720p --out out/delivery/new_snapshot.zip
.\rtl\run.ps1 tools/build_delivery.py --verify out/delivery/new_snapshot.zip
```

生成时不会覆盖已有 ZIP，重复打包需另取文件名。验证只证明文件完整，不等同于重新执行测试，更不证明板上实时达标。分享给队友前确认标准包对应的帧、LUT 与真实来源；脚本不会自动发送文件。
