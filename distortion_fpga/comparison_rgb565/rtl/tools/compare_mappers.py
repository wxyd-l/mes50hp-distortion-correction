"""Same-input RGB565 comparison of grid Q8/Q16 and direct Brown-four formula.

Generates self-contained formula packages for ModelSim and ordinary LUT packages.
No camera calibration or hardware performance is inferred from artificial data.
"""
import argparse
from dataclasses import asdict
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'algorithm'))
from fullhd_experiment import synthetic_pattern
from geometry import Mapping, View
from lens_diagnostics import synthetic_scaled_camera
from polynomial import export_parameters, fixed_points, packed_parameters
from undistort import Camera, export_grid, sample_bilinear, valid_coordinates
from reference import dense_grid, pixel_from_point
from prepare_package import prepare, rgb_to_565, rgb_from_565, read_grid, write_words


def render_coordinates(source, sx, sy, fraction=16):
    source = np.asarray(source)
    if source.ndim != 2 or min(source.shape) < 2 or source.dtype.kind not in 'iu' or np.any(source < 0) or np.any(source > 65535):
        raise ValueError('source must be a 2D normalized RGB565 integer frame')
    if type(fraction) is not int or not 1 <= fraction <= 16:
        raise ValueError('coordinate fraction must be 1..16')
    sx, sy = np.asarray(sx), np.asarray(sy)
    if sx.shape != sy.shape or sx.ndim != 2 or sx.dtype.kind not in 'iu' or sy.dtype.kind not in 'iu':
        raise ValueError('coordinate arrays must be same-shape 2D integers')
    if np.any(sx < -(1<<31)) or np.any(sx > (1<<31)-1) or np.any(sy < -(1<<31)) or np.any(sy > (1<<31)-1):
        raise ValueError('coordinates must fit signed32')
    sx, sy = sx.astype(np.int64), sy.astype(np.int64)
    height,width = source.shape
    one = 1 << fraction
    valid = (sx >= 0) & (sy >= 0) & (sx <= (width-1)*one) & (sy <= (height-1)*one)
    x0,y0 = np.clip(sx >> fraction,0,width-1),np.clip(sy >> fraction,0,height-1)
    x1,y1 = np.minimum(x0+1,width-1),np.minimum(y0+1,height-1)
    neighbors = [source[y0,x0],source[y0,x1],source[y1,x0],source[y1,x1]]
    wx,wy = sx % one,sy % one
    result = np.zeros(sx.shape,np.uint16)
    for shift,mask in ((11,31),(5,63),(0,31)):
        a,b,c,d = [(pixel.astype(np.int64) >> shift) & mask for pixel in neighbors]
        accumulator = ((a*(one-wx)+b*wx)*(one-wy)+(c*(one-wx)+d*wx)*wy)
        channel = (accumulator+(1 << (2*fraction-1))) >> (2*fraction)
        result |= (channel << shift).astype(np.uint16)
    result[~valid] = 0
    return result, valid


def exact_rgb565(source, sx, sy):
    result = np.zeros(sx.shape,np.uint16)
    for shift,mask in ((11,31),(5,63),(0,31)):
        channels = ((source >> shift) & mask).astype(np.float64)
        interpolated,_ = sample_bilinear(channels,sx,sy)
        result |= (np.floor(interpolated+.5).astype(np.uint16) << shift)
    return result


def error_metrics(sx,sy,exact_x,exact_y,pixels,exact_pixels,mask,exact_mask):
    error = np.hypot(sx-exact_x,sy-exact_y)
    common = mask & exact_mask
    color_error = []
    for shift,bits in ((11,31),(5,63),(0,31)):
        difference = ((pixels >> shift) & bits).astype(np.int16)-((exact_pixels >> shift) & bits).astype(np.int16)
        color_error.append(int(np.abs(difference[common]).max()) if common.any() else None)
    return {'coordinate_error_max_px':float(error.max()),'coordinate_error_p99_px':float(np.percentile(error,99)),
            'validity_disagreements':int(np.count_nonzero(mask != exact_mask)),
            'invalid_pixels':int(np.count_nonzero(~mask)),
            'pixel_mismatches_to_exact_float565':int(np.count_nonzero(pixels != exact_pixels)),
            'native_channel_max_error_common_valid_rgb':color_error}


def formula_package(mapping, source, out, overflow_fixture=False):
    out = Path(out)
    out.mkdir(parents=True,exist_ok=True)
    params = export_parameters(mapping)
    height,width = mapping.size[1],mapping.size[0]
    if overflow_fixture:
        params = {name:0 for name in params}
        params.update(a02=(1<<31)-1,fx=65536,fy=65536)
        sx,sy = np.zeros((height,width),np.int64),np.zeros((height,width),np.int64)
        expected = np.zeros((height,width),np.uint16)
        valid = np.zeros((height,width),bool)
    else:
        v,u = np.indices((height,width),dtype=np.int64)
        sx,sy = fixed_points(params,u,v)
        expected,valid = render_coordinates(source,sx,sy)
    files = {'source_rgb565.memh':(source,4),'expected_rgb565.memh':(expected,4),
             'expected_valid.memh':(valid,1),'expected_x.memh':(sx & 0xffffffff,8),
             'expected_y.memh':(sy & 0xffffffff,8)}
    for name,(array,digits) in files.items():write_words(out/name,array,digits)
    (out/'parameters.memh').write_text(f'{packed_parameters(params):0112x}\n',encoding='ascii')
    files['parameters.memh'] = None
    report = {'schema':'brown_formula_test_v1','input_size':list(mapping.camera.size),'output_size':list(mapping.size),
              'parameters':params,'parameter_field_bits':32,'parameter_bus_bits':448,
              'coordinate_fraction_bits':16,'pixel_format':'normalized RGB565; logical pixel addresses',
              'invalid_pixels':int(np.count_nonzero(~valid)),
              'overflow_pixels':width*height if overflow_fixture else 0,
              'mapping':mapping.metadata(),'artificial_overflow_fixture':bool(overflow_fixture),
              'sha256':{name:hashlib.sha256((out/name).read_bytes()).hexdigest() for name in files},
              'scope':'Generated numerical oracle; input/camera provenance unverified. NOT hardware/lens validation.'}
    (out/'package.json').write_text(json.dumps(report,indent=2,allow_nan=False),encoding='utf-8')
    return report,(sx,sy,expected,valid)


def compare(camera,view,out,input_path=None,step=32):
    mapping = Mapping(camera,view)
    # Reject unsupported projection before any package output is created.
    params = export_parameters(mapping)
    out = Path(out)
    if input_path is not None and Path(input_path).resolve().parent == out.resolve():
        raise ValueError('comparison output must not overlap the source image directory')
    if input_path is None:
        image = Image.fromarray(synthetic_pattern(camera.size))
    else:
        with Image.open(input_path) as loaded:
            if loaded.size != camera.size:raise ValueError('input must match camera dimensions; no implicit resize')
            image = loaded.convert('RGB')
    source = rgb_to_565(image)
    out.mkdir(parents=True,exist_ok=True)
    image.save(out/'input.png')
    exact_x,exact_y = mapping.dense()
    exact_mask = valid_coordinates(exact_x,exact_y,camera.size)
    exact_pixels = exact_rgb565(source,exact_x,exact_y)
    formula,(sx,sy,pixels,mask) = formula_package(mapping,source,out/'formula')
    metrics = {'formula_q16':error_metrics(sx/65536,sy/65536,exact_x,exact_y,pixels,exact_pixels,mask,exact_mask)}
    Image.fromarray(rgb_from_565(pixels)).save(out/'formula.png')
    for fraction in (8,16):
        name = f'grid_q{fraction}'
        export_grid(camera,out/name,step,fraction,mapping,mapping.size,mapping.metadata())
        prepare(out/name,out/'input.png',out/(name+'_package'),16)
        meta,grid = read_grid(out/name)
        qx,qy = dense_grid(grid,mapping.size,16)
        grid_pixels,grid_mask = render_coordinates(source,qx,qy,fraction)
        metrics[name] = error_metrics(qx/(1<<fraction),qy/(1<<fraction),exact_x,exact_y,
                                     grid_pixels,exact_pixels,grid_mask,exact_mask)
        metrics[name]['lut_bytes_per_bank'] = meta['memory_bytes']
        metrics[name]['pixel_mismatches_to_formula'] = int(np.count_nonzero(grid_pixels != pixels))
        Image.fromarray(rgb_from_565(grid_pixels)).save(out/(name+'.png'))
    report = {'created_at_utc':datetime.now(timezone.utc).isoformat(),'input_size':list(camera.size),
              'output_size':list(mapping.size),'view':asdict(view),'metrics':metrics,
              'formula_coefficients_bytes':len(params)*4,
              'input_sha256':hashlib.sha256((out/'input.png').read_bytes()).hexdigest(),
              'source_camera':{'k':camera.k.tolist(),'d':camera.d.tolist()},
              'input_kind':'generated artificial numeric pattern' if input_path is None else 'provided image; provenance unverified',
              'scope':'Same RGB565 source, same exact Brown-four map, whole-sample black border and replicated final '
                      'neighbor. Pixel differences are numerical metrics, NOT lens quality. Formula uses Q16 weights; '
                      'grid uses its coordinate fraction as weights. No hardware resource/speed conclusion.'}
    (out/'comparison.json').write_text(json.dumps(report,indent=2,allow_nan=False),encoding='utf-8')
    return report


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--camera',type=Path,default=ROOT/'algorithm/examples/camera_demo.json')
    p.add_argument('--input',type=Path)
    p.add_argument('--out',type=Path,default=Path('out/mapper_comparison/center30'))
    p.add_argument('--angle',type=float,default=30)
    p.add_argument('--border',choices=('keep','crop-center'),default='crop-center')
    p.add_argument('--synthetic-size',type=int,nargs=2,help='explicit artificial endpoint scaling; not camera mode calibration')
    args = p.parse_args()
    camera = Camera.load(args.camera)
    if args.synthetic_size:
        if args.input:p.error('--synthetic-size cannot be used with a real input image')
        camera = synthetic_scaled_camera(camera,args.synthetic_size)
    print(json.dumps(compare(camera,View(angle=args.angle,border=args.border,crop_safety_px=.5),args.out,args.input),indent=2))
