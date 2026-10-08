"""Validate an exported LUT and package RGB565 input/bit-exact RTL output."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys

import numpy as np
from PIL import Image

from reference import dense_grid, render_fast
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'algorithm'))
from undistort import grid_axis, interpolate_grid


def rgb_to_565(image):
    """Explicit high-bit truncation; no RGB/BGR guessing or dithering."""
    rgb = np.asarray(image, dtype=np.uint16)
    return ((rgb[...,0] >> 3) << 11) | ((rgb[...,1] >> 2) << 5) | (rgb[...,2] >> 3)


def rgb_from_565(pixels):
    # Replicate high bits to 8-bit for PNG inspection only.
    r, g, b = (pixels >> 11) & 31, (pixels >> 5) & 63, pixels & 31
    return np.stack([(r << 3) | (r >> 2), (g << 2) | (g >> 4),
                     (b << 3) | (b >> 2)], axis=-1).astype(np.uint8)


def read_grid(directory):
    metadata = json.loads((directory / 'grid.json').read_text(encoding='utf-8'))
    if metadata.get('schema') != 'experimental_grid_v1':
        raise ValueError('unsupported LUT schema')
    if metadata.get('mapping_direction') != 'output_corrected_pixel_to_input_distorted_pixel':
        raise ValueError('LUT must map output coordinates to input coordinates')
    if metadata.get('word_bits') != 64 or metadata.get('packing') != "[63:32] signed y; [31:0] signed x; two's complement":
        raise ValueError('unsupported LUT packing')
    source, output = metadata['input_size'], metadata['output_size']
    for size in (source, output):
        if len(size) != 2 or any(type(value) is not int or not 2 <= value <= 65535 for value in size):
            raise ValueError('RTL dimensions must be integers in [2,65535]')
        if size[0]*size[1] > 1 << 24:
            raise ValueError('default 24-bit pixel address cannot hold this frame')
    step = metadata['grid_step']
    if type(step) is not int or not 1 <= step <= 16384 or step & (step-1):
        raise ValueError('this RTL requires a power-of-two grid step in [1,16384]')
    fraction = metadata['frac_bits']
    if type(fraction) is not int or not 1 <= fraction <= 16:
        raise ValueError('coordinate fraction must be an integer in [1,16]')
    if max(source[0]-1,source[1]-1)*(1 << fraction) > (1 << 31)-1:
        raise ValueError('source coordinates do not fit signed int32')
    xs, ys = grid_axis(output[0],step), grid_axis(output[1],step)
    if metadata['x_nodes'] != xs.tolist() or metadata['y_nodes'] != ys.tolist():
        raise ValueError('LUT axes differ from RTL regular grid plus final endpoint')
    if metadata['grid_shape'] != [len(ys),len(xs)]:
        raise ValueError('LUT shape mismatch')
    count = len(xs)*len(ys)
    if count > 65536:
        raise ValueError('LUT exceeds the 16-bit configuration address range')
    lines = (directory / 'grid.memh').read_text(encoding='ascii').splitlines()
    if len(lines) != count or any(len(line) != 16 or any(c not in '0123456789abcdefABCDEF' for c in line) for line in lines):
        raise ValueError('LUT must have exactly one 64-bit hexadecimal word per node')
    words = np.array([int(line,16) for line in lines], dtype=np.uint64)
    def signed(values):
        values = values.astype(np.int64)
        return np.where(values >= 1 << 31, values-(1 << 32),values).reshape(len(ys),len(xs))
    qx, qy = signed(words & np.uint64(0xffffffff)), signed(words >> np.uint64(32))
    return metadata, (xs,ys,qx,qy)


def write_words(path, array, digits):
    path.write_text(''.join(f'{int(value):0{digits}x}\n' for value in array.flat), encoding='ascii')


def prepare(directory, image_path, out, weight_frac=16):
    if weight_frac not in (8,16):
        raise ValueError('weight_frac must be 8 or 16')
    if directory.resolve() == out.resolve():
        raise ValueError('package output must not overwrite the input LUT directory')
    metadata, grid = read_grid(directory)
    with Image.open(image_path) as opened:
        if opened.size != tuple(metadata['input_size']):
            raise ValueError('input frame dimensions differ from calibration; no implicit resizing')
        image = opened.convert('RGB')
    source = rgb_to_565(image)
    size, fraction = metadata['output_size'], metadata['frac_bits']
    result, mask = render_fast(source, grid, size, fraction, weight_frac)
    qx, qy = dense_grid(grid, size, weight_frac)
    float_x = interpolate_grid(grid[2]/(1 << fraction),grid[0],grid[1],size)
    float_y = interpolate_grid(grid[3]/(1 << fraction),grid[0],grid[1],size)
    error = np.hypot(qx/(1 << fraction)-float_x,qy/(1 << fraction)-float_y)
    width,height = metadata['input_size']
    float_valid = (float_x >= 0) & (float_x <= width-1) & (float_y >= 0) & (float_y <= height-1)
    out.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(directory / 'grid.memh',out / 'grid.memh')
    shutil.copyfile(directory / 'grid.json',out / 'grid.json')
    write_words(out/'source_rgb565.memh',source,4)
    write_words(out/'expected_rgb565.memh',result,4)
    write_words(out/'expected_valid.memh',mask,1)
    Image.fromarray(rgb_from_565(source)).save(out/'source_rgb565.png')
    Image.fromarray(rgb_from_565(result)).save(out/'expected_rgb565.png')
    Image.fromarray(mask.astype(np.uint8)*255).save(out/'expected_valid.png')
    parameters = {
        'SRC_WIDTH':width,'SRC_HEIGHT':height,'OUT_WIDTH':size[0],'OUT_HEIGHT':size[1],
        'GRID_LOG2':metadata['grid_step'].bit_length()-1,'COORD_FRAC':fraction,
        'WEIGHT_FRAC':weight_frac,'ADDR_BITS':24,
    }
    (out/'rtl_parameters.vh').write_text('// Generated; pass these macros to remap_frame_writer parameters.\n'+
        ''.join(f'`define REMAP_{key} {value}\n' for key,value in parameters.items()),encoding='ascii')
    files = ['grid.memh','grid.json','source_rgb565.memh','expected_rgb565.memh','expected_valid.memh','rtl_parameters.vh']
    report = {
        'schema':'rtl_test_package_v1','parameters':parameters,'node_count':int(grid[2].size),
        'lut_bytes_per_bank':int(grid[2].size*8),'lut_bytes_two_banks':int(grid[2].size*16),
        'source_frame_bytes':int(source.size*2),'output_frame_bytes':int(result.size*2),
        'input_image':str(image_path.resolve()),'input_image_sha256':hashlib.sha256(image_path.read_bytes()).hexdigest(),
        'pixel_format':'normalized RGB565: R[15:11], G[10:5], B[4:0]; RGB8 high-bit truncation',
        'runtime_rounding':'nearest, ties toward positive infinity; one final bilinear rounding',
        'invalid_pixels':int(np.count_nonzero(~mask)),
        'fixed_vs_float_same_grid_max_coordinate_error_px':float(error.max()),
        'fixed_vs_float_same_grid_p99_coordinate_error_px':float(np.percentile(error,99)),
        'fixed_vs_float_same_grid_validity_disagreements':int(np.count_nonzero(mask != float_valid)),
        'original_float_grid_vs_exact_mapping_max_error_px':metadata.get('max_coordinate_error_px'),
        'warning':'Generated oracle, not board results. Same-grid errors exclude lens/grid approximation. Input provenance is not verified.',
        'sha256':{name:hashlib.sha256((out/name).read_bytes()).hexdigest() for name in files},
    }
    (out/'package.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lut',type=Path,required=True)
    parser.add_argument('--input',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--weight-frac',type=int,choices=(8,16),default=16)
    args = parser.parse_args()
    print(json.dumps(prepare(args.lut,args.input,args.out,args.weight_frac),indent=2))
