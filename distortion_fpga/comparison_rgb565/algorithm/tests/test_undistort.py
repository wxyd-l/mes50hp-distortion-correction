import importlib.util
import json
import sys
import tempfile
import unittest
import subprocess
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from undistort import (Camera, build_map, destination_to_source, distort_normalized,
                      sample_bilinear, grid_axis, export_grid, interpolate_grid,
                      quantize_coordinates, demo_distorted_input)
from calibrate import parse_board, fit_camera


def camera(d=(0, 0, 0, 0, 0), size=(33, 25)):
    return Camera(size, [[40, 0, 16], [0, 42, 12], [0, 0, 1]], d)


class ReferenceTests(unittest.TestCase):
    def test_identity_map_and_image(self):
        c = camera()
        mx, my = build_map(c)
        v, u = np.indices((25, 33))
        np.testing.assert_allclose(mx, u, atol=1e-13)
        np.testing.assert_allclose(my, v, atol=1e-13)
        image = np.arange(25 * 33 * 3).reshape(25, 33, 3) % 251
        sampled, valid = sample_bilinear(image, mx, my)
        self.assertTrue(valid.all())
        np.testing.assert_allclose(sampled, image, atol=1e-10)

    def test_radial_direction_known_value(self):
        c = Camera((100, 100), [[10, 0, 0], [0, 10, 0], [0, 0, 1]], [0.1, 0, 0, 0, 0])
        sx, sy = destination_to_source(c, 10, 0)
        self.assertAlmostEqual(float(sx), 11.0)
        self.assertEqual(float(sy), 0.0)

    def test_tangential_known_value(self):
        x, y = distort_normalized(np.array(1.), np.array(2.), [0, 0, .01, .02, 0])
        self.assertAlmostEqual(float(x), 1.18)
        self.assertAlmostEqual(float(y), 2.21)

    def test_principal_point_unchanged(self):
        sx, sy = destination_to_source(camera([-.2, .03, .001, -.002, .01]), 16, 12)
        self.assertEqual(float(sx), 16)
        self.assertEqual(float(sy), 12)

    def test_separate_output_intrinsics(self):
        c = camera()
        out_k = [[20, 0, 5], [0, 21, 7], [0, 0, 1]]
        sx, sy = destination_to_source(c, 6, 8, out_k)
        self.assertAlmostEqual(float(sx), 18)
        self.assertAlmostEqual(float(sy), 14)

    def test_bilinear_linear_ramp(self):
        v, u = np.indices((5, 6))
        result, valid = sample_bilinear(3 * u + 7 * v, np.array([1.25, 5]), np.array([2.5, 4]))
        np.testing.assert_allclose(result, [21.25, 43])
        self.assertTrue(valid.all())

    def test_borders_and_nonfinite(self):
        result, valid = sample_bilinear(np.full((3, 4, 3), 7),
                                       np.array([-0.01, 3, 3.01, np.nan, np.inf]), np.zeros(5))
        np.testing.assert_array_equal(valid, [False, True, False, False, False])
        np.testing.assert_array_equal(result[:, 0], [0, 7, 0, 0, 0])

    def test_last_grid_cell(self):
        xs, ys = grid_axis(35, 16), grid_axis(23, 16)
        np.testing.assert_array_equal(xs, [0, 16, 32, 34])
        np.testing.assert_array_equal(ys, [0, 16, 22])
        u, v = np.meshgrid(xs, ys)
        result = interpolate_grid(3 * u + 7 * v, xs, ys, (35, 23))
        vv, uu = np.indices((23, 35))
        np.testing.assert_allclose(result, 3 * uu + 7 * vv, atol=1e-12)

    def test_quantization_and_signed_packing(self):
        np.testing.assert_array_equal(quantize_coordinates([-.5, 1.25], 8), [-128, 320])
        with tempfile.TemporaryDirectory() as tmp:
            c = camera([.2, 0, 0, 0, 0])
            meta = export_grid(c, tmp, 8, 8)
            words = [int(line, 16) for line in (Path(tmp) / 'grid.memh').read_text().splitlines()]
            gx, gy = np.meshgrid(meta['x_nodes'], meta['y_nodes'])
            expected_x, expected_y = destination_to_source(c, gx, gy)
            def signed(value):
                return value - (1 << 32) if value & (1 << 31) else value
            decoded_x = np.array([signed(w & 0xffffffff) for w in words]).reshape(gx.shape) / 256
            decoded_y = np.array([signed(w >> 32) for w in words]).reshape(gy.shape) / 256
            self.assertLess(decoded_x[0, 0], 0)  # Do not clamp invalid coordinates to zero.
            self.assertLessEqual(np.abs(decoded_x - expected_x).max(), .5 / 256)
            self.assertLessEqual(np.abs(decoded_y - expected_y).max(), .5 / 256)
            self.assertEqual(meta['memory_bytes'], len(words) * 8)
            self.assertTrue(np.isfinite(meta['max_coordinate_error_px']))

    def test_grid_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            meta = export_grid(camera(), tmp, 8, 8)
            self.assertLess(meta['max_coordinate_error_px'], 1e-12)

    def test_overflow_and_invalid_settings(self):
        for frac in [-1, 21, 1.5]:
            with self.assertRaises(ValueError):
                quantize_coordinates([0], frac)
        for values in [[1e12], [np.nan]]:
            with self.assertRaises(ValueError):
                quantize_coordinates(values, 8)
        with self.assertRaises(ValueError):
            grid_axis(33, 0)
        with self.assertRaises(ValueError):
            Camera((1, 20), np.eye(3), np.zeros(5))
        with self.assertRaises(ValueError):
            Camera((20, 20), [[1, .1, 0], [0, 1, 0], [0, 0, 1]], np.zeros(5))
        with self.assertRaises(ValueError):
            Camera((20, 20), np.eye(3), np.zeros(4))

    def test_chessboard_dimensions(self):
        self.assertEqual(parse_board('9x6'), (9, 6))
        self.assertEqual(parse_board('6X9'), (6, 9))

    def test_synthetic_zero_distortion(self):
        c = camera()
        image = np.arange(25 * 33 * 3, dtype=np.uint16).reshape(25, 33, 3) % 250
        np.testing.assert_array_equal(demo_distorted_input(image, c), image)

    def test_cli_rejects_mismatched_image_size(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            Image.new('RGB', (20, 20)).save(root / 'input.png')
            (root / 'camera.json').write_text(json.dumps({
                'model': 'brown_conrady_5', 'image_size': [33, 25],
                'camera_matrix': camera().k.tolist(), 'dist_coeffs': [0] * 5
            }), encoding='utf-8')
            result = subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / 'undistort.py'),
                                     'remap', '--camera', str(root / 'camera.json'), '--image', str(root / 'input.png'),
                                     '--out', str(root / 'output')], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('input image size differs', result.stderr)
            self.assertFalse((root / 'output').exists())


@unittest.skipUnless(importlib.util.find_spec('cv2'), 'OpenCV missing: independent comparison NOT performed')
class OpenCVComparisonTests(unittest.TestCase):
    def test_actual_chessboard_detector_dimensions(self):
        import cv2
        squares = (np.indices((7, 10)).sum(axis=0) % 2 * 255).astype(np.uint8)
        board = np.pad(np.repeat(np.repeat(squares, 40, axis=0), 40, axis=1), 60, constant_values=255)
        found, corners = cv2.findChessboardCornersSB(board, parse_board('9x6'))
        self.assertTrue(found)
        self.assertEqual(corners.reshape(-1, 2).shape, (54, 2))

    def test_maps_against_opencv(self):
        import cv2
        rng = np.random.default_rng(20261007)
        for _ in range(12):
            d = rng.uniform([-.3, -.03, -.004, -.004, -.01], [.3, .08, .004, .004, .01])
            c = camera(d)
            kout = np.array([[35, 0, 14], [0, 38, 10], [0, 0, 1]], dtype=float)
            expected_x, expected_y = cv2.initUndistortRectifyMap(c.k, c.d, None, kout, (37, 29), cv2.CV_32FC1)
            mx, my = build_map(c, (37, 29), kout)
            np.testing.assert_allclose(mx, expected_x, atol=4e-6, rtol=0)
            np.testing.assert_allclose(my, expected_y, atol=4e-6, rtol=0)

    def test_opencv_grid_aligned_pixel_interpolation(self):
        import cv2
        image = np.arange(8 * 9 * 3, dtype=np.float32).reshape(8, 9, 3)
        mx = np.array([[1.25, 4.5, 6.75]], dtype=np.float32)
        my = np.array([[2.5, 3.25, 5.75]], dtype=np.float32)
        expected = cv2.remap(image, mx, my, cv2.INTER_LINEAR)
        actual, _ = sample_bilinear(image, mx, my)
        np.testing.assert_allclose(actual, expected, atol=1e-5)

    def test_calibration_synthetic_observations(self):
        import cv2
        c = Camera((1280, 720), [[900, 0, 640], [0, 910, 360], [0, 0, 1]], [-.15, .025, .001, -.001, .002])
        obj = np.zeros((9 * 6, 3), np.float32)
        obj[:, :2] = np.mgrid[0:9, 0:6].T.reshape(-1, 2) * 24
        rng = np.random.default_rng(5)
        objects, corners = [], []
        for _ in range(20):
            rvec = rng.uniform(-.4, .4, 3)
            tvec = np.array([rng.uniform(-200, 100), rng.uniform(-120, 70), rng.uniform(550, 850)])
            points, _ = cv2.projectPoints(obj, rvec, tvec, c.k, c.d)
            objects.append(obj.copy())
            corners.append(points.astype(np.float32))
        result = fit_camera(objects, corners, c.size, radial_order=3)
        self.assertEqual(len(result['dist_coeffs']), 5)
        self.assertLess(result['rms_reprojection_error_px'], 1e-3)
        np.testing.assert_allclose(result['camera_matrix'], c.k, atol=.03)


if __name__ == '__main__':
    unittest.main()
