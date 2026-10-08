"""Check a partial final cache line and short grid cells in four RTL modes."""
import argparse
from pathlib import Path

import numpy as np
from PIL import Image

from prepare_package import prepare,rgb_from_565
from run_package_sim import simulate
from undistort import Camera,export_grid


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,default=Path('out/cache_small'))
    args=p.parse_args();out=args.out;out.mkdir(parents=True,exist_ok=True)
    camera=Camera((35,23),[[29,0,17],[0,30,11],[0,0,1]],np.zeros(5))
    export_grid(camera,out/'lut',8,8)
    source=((np.arange(805,dtype=np.uint32)*137)^0x5a69).astype(np.uint16).reshape(23,35)
    Image.fromarray(rgb_from_565(source)).save(out/'source_synthetic.png')
    for weight in (8,16):
        package=out/f'wf{weight}';prepare(out/'lut',out/'source_synthetic.png',package,weight)
        for fast in (False,True):
            simulate(package,fast_map=fast,cache=True,cache_line_log2=4,cache_set_log2=2)


if __name__=='__main__':main()
