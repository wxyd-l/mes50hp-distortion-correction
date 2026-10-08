"""Deterministic independent vectors for ModelSim/Icarus testbenches."""
import argparse
import json
from pathlib import Path
import sys

import numpy as np
from PIL import Image

from reference import blend, rgb565_blend, load_grid, grid_point, pixel_from_point, render
from generate_gamma import generate as generate_gamma
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'algorithm'))
from undistort import Camera
from geometry import Mapping,View


def hex_file(path, values, bits):
    path.write_text(''.join(f'{int(v)&((1<<bits)-1):0{(bits+3)//4}x}\n' for v in values),encoding='ascii')


def packed(words):
    value=0
    for word,bits in words:
        value=(value<<bits)|(int(word)&((1<<bits)-1))
    return value


def generate(out_dir, weight_frac=16):
    out=Path(out_dir);out.mkdir(parents=True,exist_ok=True)
    rng=np.random.default_rng(20261007)
    size=(35,23);step=8;coord_frac=8
    xs=np.unique(np.append(np.arange(0,size[0],step),size[0]-1))
    ys=np.unique(np.append(np.arange(0,size[1],step),size[1]-1))
    uu,vv=np.meshgrid(xs,ys)
    source=rng.integers(0,65536,(size[1],size[0]),dtype=np.uint16)
    # Include clear colors and extremes in addition to random texture.
    source[0,:6]=[0,65535,0xf800,0x07e0,0x001f,0x8410]
    hex_file(out/'source.memh',source.flat,16)
    grids=[]
    for index in range(2):
        if index==0:
            mx,my=uu.astype(float),vv.astype(float)
        else:
            c=Camera(size,[[29,0,17],[0,30,11],[0,0,1]],[-.18,.04,.001,-.002,0])
            mx,my=Mapping(c,View(angle=17))(uu,vv)
        grid=load_grid(mx,my,size,step,coord_frac)
        grids.append(grid)
        words=[((int(y)&0xffffffff)<<32)|(int(x)&0xffffffff) for x,y in zip(grid[2].flat,grid[3].flat)]
        hex_file(out/f'map{index}.memh',words,64)
        output,mask=render(source,grid,size,coord_frac,weight_frac)
        hex_file(out/f'frame{index}_expected.memh',output.flat,16)
        hex_file(out/f'frame{index}_valid.memh',mask.flat,1)
    queries=[(0,0),(34,22),(33,21),(32,16),(34,17),(35,0),(0,23)]
    queries += [tuple(map(int,rng.integers([0,0],[36,24]))) for _ in range(505)]
    for index,grid in enumerate(grids):
        mapper=[];engine=[]
        for x,y in queries:
            sx,sy=grid_point(x,y,grid,size,weight_frac)
            pixel,valid=pixel_from_point(source,sx,sy,coord_frac)
            mapper.append(packed([(x,16),(y,16),(sx,32),(sy,32)]))
            engine.append(packed([(x,16),(y,16),(pixel,16),(valid,1)]))
        hex_file(out/f'mapper{index}.memh',mapper,96)
        hex_file(out/f'engine{index}.memh',engine,49)
    rgb=[]
    for i in range(4096):
        pixels=list(map(int,rng.integers(0,65536,4)))
        if i<256:pixels=[i%32<<11 | i%64<<5 | i%32]*4
        if i in (256,257,258,259):pixels=[0xf800,0x07e0,0x001f,0xffff]
        fx,fy=map(int,rng.integers(0,256,2))
        if i in (256,257):fx=fy=0 if i==256 else 255
        expected=rgb565_blend(pixels,fx,fy)
        rgb.append(packed([(p,16) for p in pixels]+[(fx,8),(fy,8),(expected,16)]))
    hex_file(out/'rgb.memh',rgb,96)
    signed=[];one=1<<weight_frac
    for i in range(2048):
        values=list(map(int,rng.integers(-(1<<31),(1<<31),4,dtype=np.int64)))
        if i<4:values=[-(1<<31), (1<<31)-1, -1,0]
        wx,wy=map(int,rng.integers(0,one+1,2))
        if i<4:wx=one if i&1 else 0;wy=one if i&2 else 0
        if i==4:values=[-1,0,-1,0];wx=one//2;wy=0
        expected=blend(*values,wx,wy,weight_frac)
        signed.append(packed([(v,32) for v in values]+[(wx,32),(wy,32),(expected,32)]))
    hex_file(out/'signed.memh',signed,224)
    gamma5,gamma6=generate_gamma(out,1.8)
    gamma=[]
    for pixel in range(65536):
        value=(gamma5[pixel>>11]<<11)|(gamma6[(pixel>>5)&63]<<5)|gamma5[pixel&31]
        gamma.append(packed([(pixel,16),(value,16)]))
    hex_file(out/'gamma_expected.memh',gamma,32)
    settings=f'''`define TEST_WIDTH {size[0]}
`define TEST_HEIGHT {size[1]}
`define TEST_LOG2 3
`define TEST_FRAC {coord_frac}
`define TEST_WEIGHT_FRAC {weight_frac}
`ifndef TEST_USE_FAST_MAP
`define TEST_USE_FAST_MAP 0
`endif
`define TEST_NODES {len(xs)*len(ys)}
`define RGB_CASES {len(rgb)}
`define SIGNED_CASES {len(signed)}
`define QUERY_CASES {len(queries)}
`define GAMMA_CASES {len(gamma)}
'''
    (out/'settings.vh').write_text(settings,encoding='ascii')
    report={'seed':20261007,'source_size':list(size),'output_size':list(size),'grid_step':step,
            'coordinate_fraction_bits':coord_frac,'grid_weight_fraction_bits':weight_frac,
            'pixel_rounding':'nearest, ties toward positive infinity; per R/G/B channel',
            'coordinate_rounding':'nearest, ties toward positive infinity; signed 32-bit',
            'rgb_cases':len(rgb),'signed_cases':len(signed),'queries_per_bank':len(queries),
            'gamma_cases':len(gamma),'gamma':1.8,
            'frame_pixels':size[0]*size[1],
            'synthetic_only':True,'oracle':'integer-only Python, no DUT implementation used as expected result'}
    (out/'manifest.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--weight-frac',type=int,choices=(8,16),default=16)
    args=parser.parse_args();print(json.dumps(generate(args.out,args.weight_frac),indent=2))
