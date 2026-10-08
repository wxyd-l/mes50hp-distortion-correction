# 团队共享公式核来源

`brown_mapper_pipeline.sv` 派生自团队私有仓库 `wxyd-l/mes50hp-distortion-correction` 的本地提交 `faf35a4`，原路径为 `distortion_fpga/rtl/distortion_mapper.sv`，原源码 SHA256 为 `50f36d36201ce5884033f72bfb059e705445037ed872df208fae0648069f4eaf`。

本地副本增加来源注释并将模块名 `distortion_mapper` 改为 `brown_mapper_pipeline`，算术及流水线保持不变。对照代码独立存放在 `codex/rgb565-mapper-comparison` 分支的 `distortion_fpga/comparison_rgb565/`，队友原有源码和主分支保持不变。该来源仅记录团队内部复用，不构成公开发布或重新许可授权。

RGB565 帧写出包装、公式对照测试平台及 Python 适配工具由当前项目新增，未复制队友的 RGB888、缓存或 DDR 桥实现。接入约定及两方案边界见 `../MAPPER_COMPARISON.md`。
