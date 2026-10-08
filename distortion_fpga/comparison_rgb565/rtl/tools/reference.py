"""Integer-only, bit-exact oracle for the RTL, separate from float preview."""
from pathlib import Path
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'algorithm'))
from undistort import grid_axis, quantize_coordinates


def blend(a00, a10, a01, a11, wx, wy, frac_bits):
    one = 1 << frac_bits
    if not 0 <= wx <= one or not 0 <= wy <= one:
        raise ValueError('weights must be in [0,2**frac_bits]')
    acc = ((int(a00)*(one-wx) + int(a10)*wx)*(one-wy)
           + (int(a01)*(one-wx) + int(a11)*wx)*wy)
    return (acc + (1 << (2*frac_bits-1))) >> (2*frac_bits)


def rgb565_blend(pixels, fx, fy, frac_bits=8):
    channels = []
    for shift, mask in ((11, 31), (5, 63), (0, 31)):
        values = [(int(p) >> shift) & mask for p in pixels]
        channels.append(blend(*values, fx, fy, frac_bits))
    return (channels[0] << 11) | (channels[1] << 5) | channels[2]


def load_grid(mx, my, size, step=32, coord_frac=8):
    xs, ys = grid_axis(size[0], step), grid_axis(size[1], step)
    return xs, ys, quantize_coordinates(mx, coord_frac), quantize_coordinates(my, coord_frac)


def grid_point(x, y, grid, size, weight_frac=16):
    if not 0 <= x < size[0] or not 0 <= y < size[1]:
        return -1, -1
    xs, ys, qx, qy = grid
    ix = min(int(np.searchsorted(xs, x, side='right') - 1), len(xs)-2)
    iy = min(int(np.searchsorted(ys, y, side='right') - 1), len(ys)-2)
    dx, dy = int(xs[ix+1]-xs[ix]), int(ys[iy+1]-ys[iy])
    one = 1 << weight_frac
    wx = ((x-int(xs[ix]))*one + dx//2)//dx
    wy = ((y-int(ys[iy]))*one + dy//2)//dy
    values = []
    for nodes in (qx, qy):
        values.append(blend(nodes[iy,ix], nodes[iy,ix+1], nodes[iy+1,ix], nodes[iy+1,ix+1], wx, wy, weight_frac))
    return tuple(values)


def pixel_from_point(source, sx_q, sy_q, coord_frac=8):
    height, width = source.shape
    one = 1 << coord_frac
    if not 0 <= sx_q <= (width-1)*one or not 0 <= sy_q <= (height-1)*one:
        return 0, False
    x0, y0 = sx_q//one, sy_q//one
    x1, y1 = min(x0+1,width-1), min(y0+1,height-1)
    pixels = [source[y0,x0],source[y0,x1],source[y1,x0],source[y1,x1]]
    return rgb565_blend(pixels,sx_q%one,sy_q%one,coord_frac), True


def render(source, grid, output_size, coord_frac=8, weight_frac=16):
    output = np.empty((output_size[1],output_size[0]),np.uint16)
    mask = np.zeros(output.shape, bool)
    for y in range(output_size[1]):
        for x in range(output_size[0]):
            sx,sy = grid_point(x,y,grid,output_size,weight_frac)
            output[y,x], mask[y,x] = pixel_from_point(source,sx,sy,coord_frac)
    return output, mask


def dense_grid(grid, output_size, weight_frac=16):
    """Vectorized integer oracle, cross-checked against grid_point in tests.

    WF <= 16 and int32 nodes keep the convex accumulators within signed int64.
    There is one final rounding, never an intermediate horizontal rounding.
    """
    if not 1 <= weight_frac <= 16:
        raise ValueError('weight_frac must be in [1,16]')
    xs, ys, qx, qy = grid
    y, x = np.indices((output_size[1], output_size[0]), dtype=np.int64)
    ix = np.clip(np.searchsorted(xs, x, side='right')-1, 0, len(xs)-2)
    iy = np.clip(np.searchsorted(ys, y, side='right')-1, 0, len(ys)-2)
    dx, dy = xs[ix+1]-xs[ix], ys[iy+1]-ys[iy]
    one = 1 << weight_frac
    wx = ((x-xs[ix])*one+dx//2)//dx
    wy = ((y-ys[iy])*one+dy//2)//dy
    result = []
    for nodes in (qx, qy):
        if np.any(nodes < -(1<<31)) or np.any(nodes > (1<<31)-1):
            raise ValueError('nodes must fit signed int32')
        nodes = nodes.astype(np.int64)
        h0 = nodes[iy,ix]*(one-wx)+nodes[iy,ix+1]*wx
        h1 = nodes[iy+1,ix]*(one-wx)+nodes[iy+1,ix+1]*wx
        result.append((h0*(one-wy)+h1*wy+(1 << (2*weight_frac-1))) >> (2*weight_frac))
    return tuple(result)


def render_fast(source, grid, output_size, coord_frac=8, weight_frac=16):
    """Full-resolution bit-exact frame generation; scalar render is the oracle."""
    if not 1 <= coord_frac <= 16:
        raise ValueError('coord_frac must be in [1,16]')
    sx, sy = dense_grid(grid, output_size, weight_frac)
    one = 1 << coord_frac
    height, width = source.shape
    mask = (sx >= 0) & (sx <= (width-1)*one) & (sy >= 0) & (sy <= (height-1)*one)
    # Clip only for array indexing; invalid samples are still black, not clamped.
    x0 = np.clip(sx >> coord_frac, 0, width-1)
    y0 = np.clip(sy >> coord_frac, 0, height-1)
    x1, y1 = np.minimum(x0+1,width-1), np.minimum(y0+1,height-1)
    pixels = [source[y0,x0],source[y0,x1],source[y1,x0],source[y1,x1]]
    wx, wy = sx % one, sy % one
    output = np.zeros(sx.shape, np.uint16)
    for shift, bits in ((11,31),(5,63),(0,31)):
        values = [((p.astype(np.int64) >> shift) & bits) for p in pixels]
        h0 = values[0]*(one-wx)+values[1]*wx
        h1 = values[2]*(one-wx)+values[3]*wx
        channel = (h0*(one-wy)+h1*wy+(1 << (2*coord_frac-1))) >> (2*coord_frac)
        output |= (channel << shift).astype(np.uint16)
    output[~mask] = 0
    return output, mask
