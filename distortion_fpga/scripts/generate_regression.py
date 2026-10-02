"""Generate independent Python golden vectors for RTL regression (synthetic only)."""
from pathlib import Path
import copy
import json
import sys

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from software.reference import (synthetic_config, synthetic_image, fixed_parameters,
                                fixed_map, bilinear_fixed)

WIDTH, HEIGHT = 64, 48


def main():
    target = ROOT / 'build' / 'regression'
    target.mkdir(parents=True, exist_ok=True)
    identity = synthetic_config(WIDTH, HEIGHT)
    identity['camera_matrix'] = [[64, 0, 31.5], [0, 64, 23.5], [0, 0, 1]]
    identity['distortion'] = [0, 0, 0, 0]
    distortion = synthetic_config(WIDTH, HEIGHT)
    translation = copy.deepcopy(identity)
    translation['output_to_ideal'] = [[1, 0, -0.5], [0, 1, -0.5]]
    rotation = copy.deepcopy(distortion)
    rotation['output_to_ideal'] = [[0, -1, 55], [1, 0, -8]]
    configs = [identity, distortion, translation, rotation]
    image = synthetic_image(WIDTH, HEIGHT)
    coords, pixels, coeffs = [], [], []
    for config in configs:
        params = fixed_parameters(config)
        coeffs.extend(f'{value & 0xffffffff:08x}' for value in params.values())
        sx, sy = fixed_map(config)
        coords.extend(f'{int(x)&0xffffffff:08x}{int(y)&0xffffffff:08x}' for x, y in zip(sx.flat, sy.flat))
        output = bilinear_fixed(image, sx, sy)
        pixels.extend(f'{int(r):02x}{int(g):02x}{int(b):02x}' for r,g,b in output.reshape(-1,3))
    # An intentionally unexportable, singular map exercises runtime overflow.
    # It is an RTL fault injection, NOT a valid calibration configuration.
    fault = fixed_parameters(identity)
    fault.update(a00=0, a01=0, a02=7 << 28, a10=0, a11=0, a12=0)
    coeffs.extend(f'{value & 0xffffffff:08x}' for value in fault.values())
    pixels.extend(['000000'] * (WIDTH * HEIGHT))
    inputs = [f'{int(r):02x}{int(g):02x}{int(b):02x}' for r,g,b in image.reshape(-1,3)]
    for name, data in [('parameters.mem', coeffs), ('coordinates.mem', coords),
                       ('expected_rgb.mem', pixels), ('input_rgb.mem', inputs)]:
        (target / name).write_text('\n'.join(data)+'\n', encoding='ascii')
    metadata = {'provenance': 'SYNTHETIC TEST ONLY', 'width': WIDTH, 'height': HEIGHT,
                'cases': ['identity', 'radial_tangential', 'negative_half_pixel_border',
                          'rotation_90_with_distortion', 'intentional_overflow_fault'],
                'coordinate_cases': 4, 'frame_cases': 5, 'configs': configs,
                'overflow_fault': fault}
    (target / 'manifest.json').write_text(json.dumps(metadata, indent=2), encoding='utf-8')
    print(f'Generated {4*WIDTH*HEIGHT} coordinate and {5*WIDTH*HEIGHT} RGB golden values in {target}')


if __name__ == '__main__':
    main()
