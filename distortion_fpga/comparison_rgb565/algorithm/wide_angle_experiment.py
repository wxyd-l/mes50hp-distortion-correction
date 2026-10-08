"""Artificial wide-output-angle and +/-60 degree rotation LUT stress checks."""
import argparse
from datetime import datetime, timezone
from pathlib import Path
import json

import numpy as np

from geometry import Mapping, View
from lens_diagnostics import inspect_brown, synthetic_wide_camera
from pipeline import write_json
from rotation_experiment import roi_metrics
from undistort import Camera, export_grid, valid_coordinates


def run(camera_path, out, angles=(-60, -45, -30, 0, 30, 45, 60)):
    if not angles or not np.isfinite(angles).all() or len(set(angles)) != len(angles):
        raise ValueError('angles must be distinct finite numbers')
    base = Camera.load(camera_path)
    fixtures = [('moderate_demo', base), ('wide_output_120_assumption', synthetic_wide_camera(base.size))]
    rows = []
    for name, camera in fixtures:
        diagnostic = inspect_brown(camera)
        if not diagnostic['sampled_local_check_passed']:
            raise AssertionError('synthetic fixture has suspicious local model behavior')
        for angle in angles:
            for border in ('keep', 'crop-center'):
                view = View(angle=angle, border=border, crop_safety_px=.5)
                mapping = Mapping(camera, view)
                mx, my = mapping.dense()
                valid = valid_coordinates(mx, my, camera.size)
                invalid = int(np.count_nonzero(~valid))
                if border == 'crop-center' and invalid:
                    raise AssertionError('center crop exact map has invalid samples')
                lut = export_grid(camera, Path(out)/name/f'angle{angle:g}_{border}',
                                  map_function=mapping, transform_metadata=mapping.metadata())
                rows.append({'fixture': name, 'angle': angle, 'border': border,
                             'invalid_exact_pixels': invalid, **roi_metrics(mapping.metadata(), camera.size),
                             'grid_error_max_px': lut['max_coordinate_error_px'],
                             'grid_error_p99_px': lut['p99_coordinate_error_px'],
                             'grid_validity_disagreements': lut['validity_disagreements'],
                             'lut_bytes_per_bank': lut['memory_bytes'], 'local_model_check': diagnostic})
                print(f'{name} {angle:g} {border}: invalid={invalid}, error={lut["max_coordinate_error_px"]:.4f}px', flush=True)
    summary = {'created_at_utc': datetime.now(timezone.utc).isoformat(), 'cases': rows,
               'input_size': list(base.size), 'artificial_only': True,
               'reported_lens_fov': {'degrees': 120, 'certainty': 'tentative user report',
                                     'axis': 'unknown', 'projection_model': 'unknown'},
               'scope': '120 is an assumed IDEAL OUTPUT horizontal FOV in a separate arbitrary Brown fixture, '
                        'not the reported physical lens. No real K/D is inferred. Rotation is planar angle, '
                        'not pitch/yaw or physical FOV. ROI area is base-canvas area, not recovered scene FOV.'}
    write_json(Path(out)/'summary.json', summary)
    return summary


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--camera', type=Path, default=Path('examples/camera_demo.json'))
    p.add_argument('--out', type=Path, default=Path('out/wide_angle'))
    args = p.parse_args()
    result = run(args.camera, args.out)
    print(json.dumps({'cases': len(result['cases']), 'out': str(args.out.resolve())}))
