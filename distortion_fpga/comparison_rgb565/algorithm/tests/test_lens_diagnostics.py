import unittest
import json
import sys
import tempfile
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lens_diagnostics import brown_jacobian, inspect_brown, synthetic_scaled_camera, synthetic_wide_camera
from undistort import Camera, distort_normalized, destination_to_source
from fullhd_experiment import synthetic_pattern
from wide_angle_experiment import run


class LensDiagnosticsTests(unittest.TestCase):
    def test_identity_derivative(self):
        xx, xy, yy = brown_jacobian([0, 1], [0, -2], [0]*5)
        np.testing.assert_array_equal(xx, [1, 1])
        np.testing.assert_array_equal(xy, [0, 0])
        np.testing.assert_array_equal(yy, [1, 1])

    def test_derivative_matches_finite_difference(self):
        rng = np.random.default_rng(7640)
        x, y = rng.uniform(-2, 2, (2, 200))
        d = [-.08, .008, .003, -.002, .0001]
        xx, xy, yy = brown_jacobian(x, y, d)
        h = 1e-6
        xp, yp = distort_normalized(x+h, y, d)
        xm, ym = distort_normalized(x-h, y, d)
        np.testing.assert_allclose((xp-xm)/(2*h), xx, atol=2e-9, rtol=2e-9)
        np.testing.assert_allclose((yp-ym)/(2*h), xy, atol=2e-9, rtol=2e-9)
        xp, yp = distort_normalized(x, y+h, d)
        xm, ym = distort_normalized(x, y-h, d)
        np.testing.assert_allclose((xp-xm)/(2*h), xy, atol=2e-9, rtol=2e-9)
        np.testing.assert_allclose((yp-ym)/(2*h), yy, atol=2e-9, rtol=2e-9)

    def test_fold_is_flagged(self):
        camera = Camera((41, 25), [[10, 0, 20], [0, 10, 12], [0, 0, 1]], [-1, 0, 0, 0, 0])
        report = inspect_brown(camera, (41, 25))
        self.assertFalse(report['sampled_local_check_passed'])
        self.assertGreater(report['nonmonotone_or_nearly_singular_samples'], 0)

    def test_artificial_wide_fixture_local_check(self):
        self.assertTrue(inspect_brown(synthetic_wide_camera())['sampled_local_check_passed'])

    def test_scale_preserves_normalized_map(self):
        base = synthetic_wide_camera((80, 50))
        scaled = synthetic_scaled_camera(base, (160, 90))
        sx, sy = 159/79, 89/49
        a, b = destination_to_source(base, [0, 20, 79], [0, 22, 49])
        c, d = destination_to_source(scaled, np.array([0, 20, 79])*sx, np.array([0, 22, 49])*sy)
        np.testing.assert_allclose(c, a*sx, atol=1e-12)
        np.testing.assert_allclose(d, b*sy, atol=1e-12)
        self.assertEqual(base.size, (80, 50))

    def test_invalid_fov(self):
        for fov in (0, -1, 180, np.nan, np.inf):
            with self.assertRaises(ValueError): synthetic_wide_camera(output_hfov=fov)

    def test_sampling_limits(self):
        for size in ((1, 4), (2.5, 4), (10000, 10000)):
            with self.assertRaises(ValueError): inspect_brown(synthetic_wide_camera(), size)

    def test_invalid_derivative_inputs(self):
        for d in ([0]*4, [np.nan]*5):
            with self.assertRaises(ValueError): brown_jacobian(0, 0, d)
        with self.assertRaises(ValueError): brown_jacobian(np.inf, 0, [0]*5)

    def test_stress_pattern(self):
        pattern = synthetic_pattern((35, 23))
        self.assertEqual(pattern.shape, (23, 35, 3))
        self.assertEqual(pattern.dtype, np.uint8)
        np.testing.assert_array_equal(pattern[0, 0], [0, 0, 0])
        self.assertGreater(np.unique(pattern.reshape(-1, 3), axis=0).shape[0], 700)

    def test_small_wide_experiment(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            camera = synthetic_wide_camera((41, 25), 80)
            data = {'model': 'brown_conrady_5', 'image_size': list(camera.size),
                    'camera_matrix': camera.k.tolist(), 'dist_coeffs': camera.d.tolist()}
            path = directory/'camera.json'
            path.write_text(json.dumps(data), encoding='utf-8')
            report = run(path, directory/'out', (-45, 45))
            self.assertEqual(len(report['cases']), 8)
            self.assertTrue(report['artificial_only'])
            for row in report['cases']:
                if row['border'] == 'crop-center': self.assertEqual(row['invalid_exact_pixels'], 0)
            self.assertEqual(json.loads(path.read_text()), data)
            self.assertEqual(len(list((directory/'out').glob('*/*/grid.memh'))), 8)

    def test_invalid_experiment_angles(self):
        for angles in ((), (0, 0), (float('nan'),)):
            with self.assertRaises(ValueError): run(Path('missing.json'), Path('unused'), angles)

    def test_nonfinite_extreme_model_is_flagged(self):
        camera = Camera((41, 25), [[10, 0, 20], [0, 10, 12], [0, 0, 1]], [1e308, 0, 0, 0, 0])
        report = inspect_brown(camera, (5, 5))
        self.assertFalse(report['sampled_local_check_passed'])
        self.assertGreater(report['nonfinite_samples'], 0)
