"""Logical RGB565 read traces and hypothetical cold, read-only cache estimates.

This does not implement a DDR controller, predict timing, or measure bandwidth.
The trace follows the current serial engine's four reads per valid output pixel.
"""
import argparse
from datetime import datetime, timezone
import hashlib
from pathlib import Path
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'rtl' / 'tools'))
from prepare_package import read_grid
from reference import dense_grid
from pipeline import write_json
from undistort import checked_size


def integer_addresses(values):
    values = np.asarray(values)
    if not values.size:
        return np.empty(0, np.int64)
    if values.dtype.kind not in 'iu' or np.any(values < 0) or np.any(values > np.iinfo(np.int64).max):
        raise ValueError('addresses must be nonnegative int64-compatible integers')
    return values.astype(np.int64, copy=False).reshape(-1)


def source_read_trace(sx, sy, source_size, coord_frac=8):
    """Row-major output; p00,p10,p01,p11; invalid pixels issue ZERO reads.

    Edge neighbors are replicated, even when interpolation weights are zero.
    Addresses are logical pixel indices, not byte or physical DDR addresses.
    """
    width, height = checked_size(source_size)
    if type(coord_frac) is not int or not 1 <= coord_frac <= 16:
        raise ValueError('coord_frac must be an integer in [1,16]')
    sx, sy = np.asarray(sx), np.asarray(sy)
    if sx.shape != sy.shape or sx.ndim != 2 or sx.dtype.kind not in 'iu' or sy.dtype.kind not in 'iu':
        raise ValueError('coordinates must be matching 2-D integer arrays')
    if any(np.any(a > (1 << 31)-1) or np.any(a < -(1 << 31)) for a in (sx, sy)):
        raise ValueError('coordinates must fit signed int32')
    one = 1 << coord_frac
    mask = (sx >= 0) & (sx <= (width-1)*one) & (sy >= 0) & (sy <= (height-1)*one)
    x0, y0 = sx[mask].astype(np.int64) >> coord_frac, sy[mask].astype(np.int64) >> coord_frac
    x1, y1 = np.minimum(x0+1, width-1), np.minimum(y0+1, height-1)
    trace = np.stack((y0*width+x0, y0*width+x1, y1*width+x0, y1*width+x1), axis=-1).reshape(-1)
    return trace, mask


def cache_stats(addresses, capacity_bytes, line_bytes=32, ways=2):
    """Exact LRU per set; cold start; full aligned line on every demand miss.

    Only adjacent equal LINE requests are compressed, never reordered. Tag and
    control storage, DDR arbitration/latency and cache throughput are excluded.
    """
    for name, value in (('capacity_bytes', capacity_bytes), ('line_bytes', line_bytes), ('ways', ways)):
        if type(value) is not int or value <= 0 or value & (value-1):
            raise ValueError(f'{name} must be a positive power-of-two integer')
    if line_bytes < 2 or capacity_bytes < line_bytes*ways:
        raise ValueError('capacity must hold at least one set; line must hold RGB565 pixels')
    addresses = integer_addresses(addresses)
    line_pixels = line_bytes//2
    lines = addresses//line_pixels
    sets = capacity_bytes//(line_bytes*ways)
    tags = [[-1]*ways for _ in range(sets)]  # MRU first, LRU last.
    if lines.size:
        starts = np.flatnonzero(np.r_[True, lines[1:] != lines[:-1]])
        counts = np.diff(np.r_[starts, lines.size])
    else:
        starts, counts = np.empty(0, np.int64), np.empty(0, np.int64)
    misses = hits = 0
    for line, repetitions in zip(lines[starts].tolist(), counts.tolist()):
        bucket = tags[line % sets]
        tag = line//sets
        try:
            position = bucket.index(tag)
            hits += repetitions
            bucket.pop(position)
        except ValueError:
            misses += 1
            hits += repetitions-1
            bucket.pop()
        bucket.insert(0, tag)
    return {'capacity_data_bytes': capacity_bytes, 'line_bytes': line_bytes,
            'ways': ways, 'sets': sets, 'requests': int(lines.size),
            'hits': hits, 'misses': misses, 'hit_fraction': hits/int(lines.size) if lines.size else None,
            'miss_fill_bytes_per_frame': misses*line_bytes,
            'unique_lines': int(np.unique(lines).size)}


def traffic_bytes(source_size, output_size, source_read_bytes):
    """One capture write, remap source reads, output write and display read.

    Hypothetical packed independent RGB565 frames. No padding, refresh,
    metadata, commands, LUT uploads, repeated scans or inefficient bursts.
    """
    sw, sh = checked_size(source_size)
    ow, oh = checked_size(output_size)
    if type(source_read_bytes) is not int or source_read_bytes < 0:
        raise ValueError('source_read_bytes must be a nonnegative integer')
    parts = {'capture_write': sw*sh*2, 'remap_source_read': source_read_bytes,
             'remap_output_write': ow*oh*2, 'display_read': ow*oh*2}
    return {'parts_bytes_per_frame': parts, 'total_bytes_per_frame': sum(parts.values())}


def profile(directory, capacities=(2048, 8192, 32768, 131072), line_bytes=32, ways=2,
            weight_frac=16, assumed_fps=30.):
    directory = Path(directory)
    if not capacities or weight_frac not in (8, 16) or not np.isfinite(assumed_fps) or assumed_fps <= 0:
        raise ValueError('need capacities, weight_frac 8/16, and positive finite assumed_fps')
    metadata, grid = read_grid(directory)
    sx, sy = dense_grid(grid, metadata['output_size'], weight_frac)
    trace, mask = source_read_trace(sx, sy, metadata['input_size'], metadata['frac_bits'])
    uncached = traffic_bytes(metadata['input_size'], metadata['output_size'], int(trace.size*2))
    uncached['assumed_MB_per_second'] = uncached['total_bytes_per_frame']*assumed_fps/1e6
    configurations = []
    for capacity in capacities:
        stats = cache_stats(trace, capacity, line_bytes, ways)
        traffic = traffic_bytes(metadata['input_size'], metadata['output_size'], stats['miss_fill_bytes_per_frame'])
        stats['traffic'] = {**traffic, 'assumed_MB_per_second': traffic['total_bytes_per_frame']*assumed_fps/1e6}
        configurations.append(stats)
    return {'schema': 'logical_read_cache_profile_v1', 'created_at_utc': datetime.now(timezone.utc).isoformat(),
            'lut_directory': str(directory.resolve()),
            'lut_sha256': {name: hashlib.sha256((directory/name).read_bytes()).hexdigest()
                           for name in ('grid.memh', 'grid.json')},
            'input_size': metadata['input_size'], 'output_size': metadata['output_size'],
            'transform': metadata.get('transform'), 'weight_frac': weight_frac,
            'valid_output_pixels': int(mask.sum()), 'invalid_output_pixels': int((~mask).sum()),
            'logical_source_reads': int(trace.size), 'unique_source_pixels': int(np.unique(trace).size),
            'logical_uncached_read_payload_bytes': int(trace.size*2),
            'assumed_fps': float(assumed_fps), 'uncached_traffic': uncached, 'configurations': configurations,
            'assumptions': ['Output raster order and FOUR reads per valid pixel, including zero-weight neighbors.',
                'Frame origin cache-line aligned, tightly packed RGB565, immutable source, cold cache per frame.',
                'Read-only set-associative LRU, modulo set indexing, no prefetch; full line fills on misses.',
                'Frame allocation padded to line boundary; fills may include padding beyond last pixel.',
                'Capacity includes ONLY pixel data, not tags, control, buffers or FPGA BRAM granularity.',
                'One capture write, one output write and one display read included in traffic estimates.'],
            'warning': 'Analytical access model, NOT a DDR adapter or timing/throughput simulation. '
                       'No measured FPS, physical burst/transaction count, BRAM count or real-time guarantee. '
                       'Uncached numbers are requested pixel payload, not physical DDR traffic. '
                       'Cache-line overfetch can increase traffic; do not infer hardware speedup from hit rate.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lut', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--capacities', type=int, nargs='+', default=[2048,8192,32768,131072])
    parser.add_argument('--line-bytes', type=int, default=32)
    parser.add_argument('--ways', type=int, default=2)
    parser.add_argument('--weight-frac', type=int, choices=(8,16), default=16)
    parser.add_argument('--assumed-fps', type=float, default=30)
    args = parser.parse_args()
    if args.out.resolve() in ((args.lut/'grid.json').resolve(), (args.lut/'grid.memh').resolve()):
        parser.error('output must not overwrite LUT inputs')
    report = profile(args.lut,args.capacities,args.line_bytes,args.ways,args.weight_frac,args.assumed_fps)
    write_json(args.out, report)
    print(f"Valid pixels {report['valid_output_pixels']}; logical reads {report['logical_source_reads']}")
    for row in report['configurations']:
        print(f"Cache data {row['capacity_data_bytes']} bytes: hits={row['hit_fraction']}, "
              f"misses={row['misses']}, fill={row['miss_fill_bytes_per_frame']} bytes/frame")
    print('Analytical assumptions only; not measured FPGA throughput.')
