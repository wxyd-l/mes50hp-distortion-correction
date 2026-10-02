# 离线验证工具

Python建议使用3.10及以上版本，依赖numpy、opencv-python、Pillow；测试使用标准库unittest。安装可放入项目虚拟环境，无需修改全局Python。

RTL使用Icarus Verilog和vvp。脚本优先寻找PATH中的原生工具。本次实际采用现有Ubuntu-22.04 WSL，将Ubuntu官方Icarus 11.0软件包解压到项目目录，未安装系统级软件：

```sh
cd /mnt/e/code/fpga/distortion_fpga
mkdir -p tools/iverilog-wsl
cd tools/iverilog-wsl
apt-get download iverilog
dpkg-deb -x iverilog_*.deb .
```

便携包需要显式指定编译器后端目录：

```sh
./usr/bin/iverilog -B ./usr/lib/x86_64-linux-gnu/ivl -V
```

`scripts/run_hdl.py`自动处理此路径，默认WSL发行版为Ubuntu-22.04，可用环境变量FPGA_WSL_DISTRO修改。Linux/原生Windows上的完整Icarus安装直接使用PATH。

PDS不用于上述行为仿真。板级综合、布局布线、专有DDR/PLL/FIFO IP仿真须后续安装并使用对应版本PDS；本项目不修改许可证或伪造工具输出。

工具依据：[Icarus官方文档](https://steveicarus.github.io/iverilog/)、本机Ubuntu软件包元数据。算法定义依据：[OpenCV相机标定文档](https://docs.opencv.org/4.13.0/dc/dbb/tutorial_py_calibration.html)。
