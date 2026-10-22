# FPGA 畸变矫正项目

实现位于 [distortion_fpga/README.md](distortion_fpga/README.md)，对应本目录选题指南PDF的第二题，目标为盘古50K MES50HP。

算法包含镜头畸变、双线性插值、三维姿态／透视映射、自适应Gamma，以及标定、直线度和SFR/MTF50工具。软件模型与RTL逐像素对拍由统一命令复现；实时吞吐优化和板级接入见项目说明。

## 队友开始使用

这是团队私有仓库。获得邀请并接受后，再登录自己的GitHub账号克隆：

```sh
git clone https://github.com/wxyd-l/mes50hp-distortion-correction.git
cd mes50hp-distortion-correction/distortion_fpga
python -m venv .venv
```

激活虚拟环境（Windows PowerShell：`.venv\Scripts\Activate.ps1`；Linux：`source .venv/bin/activate`），然后运行：

```sh
python -m pip install -r software/requirements.txt
python scripts/verify.py --software-only
python -m software.cli algorithm-demo
```

完整RTL验证还需要Icarus Verilog；安装好`iverilog`和`vvp`后执行`python scripts/verify.py`。可选的通用综合结构检查使用Yosys，详见[工具说明](distortion_fpga/docs/tool_setup.md)和[综合检查](distortion_fpga/docs/synthesis_check.md)。文档里的`C:/Users/Lenovo/...`和`E:/code/fpga/...`是原开发机路径，新电脑使用自己的Python和克隆路径。

提交新功能前使用自己的分支，并通过Pull Request协作：

```sh
git switch -c feature/your-change
```

仓库包含自研源码、测试、文档和验证摘要。厂商资料、安装包、许可证、`vendor/`、`tools/`、`build/`及虚拟环境不会上传。离线测试无需厂商资料；板级接入时由团队通过自己的资料渠道取得原包，并按硬件审计说明放置。图片、黄金向量和完整日志可以通过验证命令重新生成。
