"""Generate an artificial 1080P/30-degree center-crop reference, not real video."""
import argparse
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
import json

import numpy as np
from PIL import Image

from geometry import View
from lens_diagnostics import inspect_brown, synthetic_scaled_camera
from pipeline import save_result, write_json
from undistort import Camera


def synthetic_pattern(size):
    width, height = size
    v, u = np.indices((height, width), dtype=np.uint32)
    return np.stack(((3*u+v) % 256, (u+5*v) % 256,
                     ((u//17+v//13) % 2)*180+(u+v) % 64), axis=-1).astype(np.uint8)


def run(camera_path, out):
    camera = synthetic_scaled_camera(Camera.load(camera_path), (1920, 1080))
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    source = synthetic_pattern(camera.size)
    Image.fromarray(source).save(out/'input_synthetic.png')
    write_json(out/'camera_artificial.json', {'model': 'brown_conrady_5', 'image_size': list(camera.size),
               'camera_matrix': camera.k.tolist(), 'dist_coeffs': camera.d.tolist(),
               'warning': 'ARTIFICIAL stress fixture only; NOT calibrated OV5640 1080P intrinsics.'})
    view = View(angle=30, border='crop-center', crop_safety_px=.5)
    _, report = save_result(source, camera, view, out/'center30')
    if report['valid_fraction'] != 1:
        raise AssertionError('1080P exact center crop is not all valid')
    write_json(out/'view.json', asdict(view))
    summary = {'created_at_utc': datetime.now(timezone.utc).isoformat(),
               'artificial_only': True, 'local_model_check': inspect_brown(camera),
               'report': report,
               'scope': 'Artificial RGB test pattern and endpoint-scaled demo Brown calibration. '
                        'NOT an OV5640 mode transform, lens quality test, real 120-degree camera or board throughput test.'}
    write_json(out/'summary.json', summary)
    return summary


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--camera', type=Path, default=Path('examples/camera_demo.json'))
    p.add_argument('--out', type=Path, default=Path('out/fullhd'))
    args = p.parse_args()
    print(json.dumps(run(args.camera, args.out), ensure_ascii=False, indent=2))
