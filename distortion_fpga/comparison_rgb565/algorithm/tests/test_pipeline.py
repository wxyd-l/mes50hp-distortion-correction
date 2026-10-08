import importlib.util
import json
from math import erf, log, pi, sqrt
from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from undistort import Camera, valid_coordinates, export_grid, demo_distorted_input
from geometry import View, Mapping, rotation_matrix, affine_matrix, largest_valid_rectangle
from quality import line_error, slanted_edge_sfr, grayscale, chessboard_straightness
from pipeline import enhance_image, process_frame, save_result, angle_commands, process_video, sweep_lut
from calibrate import fit_camera


def camera(d=None, size=(80, 60)):
    return Camera(size, [[70, 0, (size[0]-1)/2], [0, 71, (size[1]-1)/2], [0, 0, 1]],
                  np.zeros(5) if d is None else d)


def gaussian_edge(sigma=1.4, slope=.1, size=(160, 160)):
    yy, xx = np.indices(size, dtype=float)
    distance = (xx - slope * yy - size[1] / 2 + 8) / sqrt(1 + slope ** 2)
    return .5 + .3 * np.vectorize(erf)(distance / (sqrt(2) * sigma))


class GeometryTests(unittest.TestCase):
    def test_extended_demo_scene_origin(self):
        c = camera()
        extended = np.arange(80 * 100 * 3).reshape(80, 100, 3) % 251
        result = demo_distorted_input(extended, c, (-10, -10))
        np.testing.assert_array_equal(result, extended[10:70, 10:90])

    def test_identity(self):
        c = camera()
        m = Mapping(c)
        x, y = m.dense()
        yy, xx = np.indices((60, 80))
        np.testing.assert_allclose(x, xx, atol=1e-12)
        np.testing.assert_allclose(y, yy, atol=1e-12)
        self.assertTrue(valid_coordinates(x, y, c.size).all())

    def test_clockwise_rotation_known_value(self):
        c = camera(size=(81, 61))
        m = Mapping(c, View(angle=90))
        x, y = m(40, 35)
        self.assertAlmostEqual(float(x), 45)
        self.assertAlmostEqual(float(y), 30)

    def test_shift_and_scale(self):
        c = camera(size=(81, 61))
        m = Mapping(c, View(scale=2, shift_x=5, shift_y=-3))
        x, y = m(49, 31)
        self.assertAlmostEqual(float(x), 42)
        self.assertAlmostEqual(float(y), 32)

    def test_rotation_orthonormal(self):
        r = rotation_matrix(17, -8, 11)
        np.testing.assert_allclose(r.T @ r, np.eye(3), atol=1e-14)
        self.assertAlmostEqual(np.linalg.det(r), 1)

    def test_full_turn(self):
        np.testing.assert_allclose(affine_matrix((80, 60), 360), np.eye(3), atol=1e-12)

    def test_crop_resize_valid_and_same_aspect(self):
        c = camera([.1, .015, .001, -.001, 0])
        m = Mapping(c, View(angle=23, border='crop-resize'))
        x, y = m.dense()
        self.assertEqual(m.size, c.size)
        self.assertTrue(valid_coordinates(x, y, c.size).all())
        roi = m.roi
        self.assertAlmostEqual((roi[2]-1)/(roi[3]-1), (c.size[0]-1)/(c.size[1]-1))
        self.assertLess(m.base_valid_fraction, 1)

    def test_crop_changes_size(self):
        m = Mapping(camera(), View(angle=25, border='crop'))
        self.assertLess(m.size[0] * m.size[1], 80 * 60)
        self.assertTrue(valid_coordinates(*m.dense(), m.camera.size).all())

    def test_horizon_and_back_facing(self):
        c = camera()
        m = Mapping(c, View(yaw=180))
        self.assertTrue(np.isnan(m.dense()[0]).all())
        with self.assertRaises(ValueError):
            Mapping(c, View(yaw=180, border='crop-resize'))
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                export_grid(c, tmp, map_function=m, transform_metadata=m.metadata())

    def test_largest_rectangle_brute_force(self):
        rng = np.random.default_rng(43)
        for _ in range(25):
            mask = rng.random((5, 6)) > .22
            brute = 0
            for y in range(4):
                for x in range(5):
                    for hh in range(2, 6-y):
                        for ww in range(2, 7-x):
                            if mask[y:y+hh, x:x+ww].all():
                                brute = max(brute, hh*ww)
            if brute:
                x, y, w, h = largest_valid_rectangle(mask)
                self.assertEqual(w*h, brute)
                self.assertTrue(mask[y:y+h, x:x+w].all())
            else:
                with self.assertRaises(ValueError):
                    largest_valid_rectangle(mask)

    def test_invalid_view(self):
        for kwargs in ({'scale': 0}, {'angle': np.nan}, {'border': 'fill-fake-content'}):
            with self.assertRaises(ValueError):
                View(**kwargs)

    def test_composed_grid_metadata(self):
        c = camera([-.1, .01, .001, 0, 0])
        m = Mapping(c, View(angle=15, border='crop-resize'))
        with tempfile.TemporaryDirectory() as tmp:
            meta = export_grid(c, tmp, 8, 8, m, m.size, m.metadata())
            self.assertEqual(meta['transform']['view']['angle'], 15)
            self.assertIsNone(meta['output_camera_matrix'])
            self.assertLess(meta['max_coordinate_error_px'], .1)

    def test_dynamic_commands(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'commands.json'
            path.write_text(json.dumps([{'frame': 0, 'view': {'angle': 0}}, {'frame': 3, 'view': {'angle': 20}}]))
            commands = angle_commands(path)
            self.assertEqual(commands[1][1].angle, 20)
            for data in ([{'frame': 1, 'view': {}}], [{'frame': 0, 'view': {}}, {'frame': 0, 'view': {}}], [{'frame': -1, 'view': {}}]):
                path.write_text(json.dumps(data))
                with self.assertRaises(ValueError):
                    angle_commands(path)


class QualityTests(unittest.TestCase):
    def test_straight_line_arbitrary_orientation(self):
        x = np.linspace(-30, 20, 100)
        self.assertLess(line_error(np.column_stack((x, .7*x+4)))['rms_orthogonal_error_px'], 1e-12)

    def test_curvature_detected(self):
        x = np.linspace(-30, 20, 100)
        report = line_error(np.column_stack((x, .01*x*x)))
        self.assertGreater(report['rms_orthogonal_error_px'], 1)
        self.assertGreater(report['max_orthogonal_error_px'], 2)

    def test_line_invalid(self):
        for points in ([[0, 0]]*3, [[0, 0], [1, 1]], [[0, 0], [1, 1], [np.nan, 2]]):
            with self.assertRaises(ValueError):
                line_error(points)

    def test_gaussian_mtf50_against_analytic(self):
        sigma = 1.4
        report = slanted_edge_sfr(gaussian_edge(sigma))
        analytic = sqrt(log(2)) / (sqrt(2) * pi * sigma)
        self.assertAlmostEqual(report['mtf50_cycles_per_pixel'], analytic, delta=.008)

    def test_blur_lowers_mtf50(self):
        sharp = slanted_edge_sfr(gaussian_edge(1.0))['mtf50_cycles_per_pixel']
        blurred = slanted_edge_sfr(gaussian_edge(2.0))['mtf50_cycles_per_pixel']
        self.assertGreater(sharp, blurred)

    def test_horizontal_edge(self):
        report = slanted_edge_sfr(gaussian_edge().T)
        self.assertTrue(report['transposed'])
        self.assertIsNotNone(report['mtf50_cycles_per_pixel'])

    def test_srgb_linearization(self):
        linear = np.array([[0., .1, .4, 1.]])
        encoded = np.where(linear <= .0031308, linear * 12.92, 1.055 * linear**(1/2.4)-.055)
        np.testing.assert_allclose(grayscale(encoded, 'srgb'), linear, atol=1e-12)

    def test_sfr_rejects_flat_axis_aligned_small(self):
        for edge in (np.full((80, 80), .5), gaussian_edge(slope=0), np.zeros((20, 20))):
            with self.assertRaises(ValueError):
                slanted_edge_sfr(edge)

    def test_gamma_identity_and_brighten(self):
        image = np.full((20, 20, 3), 64, dtype=np.uint8)
        np.testing.assert_array_equal(enhance_image(image, 'gamma', 1)[0], image)
        self.assertGreater(enhance_image(image, 'gamma', 2)[0].mean(), image.mean())
        auto, report = enhance_image(image, 'auto-gamma')
        self.assertTrue(115 <= auto.mean() <= 140)
        self.assertGreater(report['gamma'], 1)

    def test_process_frame_keeps_invalid_black(self):
        c = camera()
        m = Mapping(c, View(angle=25))
        image = np.full((60, 80, 3), 80, dtype=np.uint8)
        result, valid, _, _, _ = process_frame(image, m, 'gamma', 2)
        self.assertFalse(valid.all())
        self.assertTrue((result[~valid] == 0).all())

    def test_save_result_and_sweep(self):
        c = camera([-.1, .01, 0, 0, 0], (40, 30))
        image = np.full((30, 40, 3), 127, dtype=np.uint8)
        with tempfile.TemporaryDirectory() as tmp:
            save_result(image, c, View(angle=10, border='crop-resize'), Path(tmp)/'image')
            rows = sweep_lut(c, View(), Path(tmp)/'sweep', [8, 16], [4, 8])
            self.assertEqual(len(rows), 4)
            self.assertTrue((Path(tmp)/'image'/'corrected.png').exists())
            self.assertTrue((Path(tmp)/'image'/'grid.memh').exists())
            self.assertTrue((Path(tmp)/'sweep'/'sweep.json').exists())


@unittest.skipUnless(importlib.util.find_spec('cv2'), 'OpenCV unavailable: independent comparisons not performed')
class OpenCVTests(unittest.TestCase):
    def test_pose_map_against_opencv(self):
        import cv2
        c = camera([-.2, .04, .001, -.001, 0])
        for view in (View(roll=20), View(roll=8, pitch=5, yaw=-7), View(pitch=-12, yaw=10)):
            r = rotation_matrix(view.roll, view.pitch, view.yaw)
            expected_x, expected_y = cv2.initUndistortRectifyMap(c.k, c.d, r, c.k, c.size, cv2.CV_32FC1)
            mx, my = Mapping(c, view).dense()
            np.testing.assert_allclose(mx, expected_x, atol=8e-6, rtol=0)
            np.testing.assert_allclose(my, expected_y, atol=8e-6, rtol=0)

    def test_affine_against_opencv(self):
        import cv2
        c = camera()
        h = affine_matrix(c.size, 17, .8, 3, -2)
        inverse = cv2.invertAffineTransform(h[:2])
        vv, uu = np.indices((60, 80))
        expected_x = inverse[0, 0]*uu + inverse[0, 1]*vv + inverse[0, 2]
        expected_y = inverse[1, 0]*uu + inverse[1, 1]*vv + inverse[1, 2]
        mx, my = Mapping(c, View(angle=17, scale=.8, shift_x=3, shift_y=-2)).dense()
        np.testing.assert_allclose(mx, expected_x, atol=1e-12)
        np.testing.assert_allclose(my, expected_y, atol=1e-12)

    def test_second_order_calibration(self):
        import cv2
        c = camera([-.15, .025, .001, -.001, 0], (1280, 720))
        k = np.array([[900, 0, 640], [0, 910, 360], [0, 0, 1]], dtype=float)
        obj = np.zeros((54, 3), np.float32)
        obj[:, :2] = np.mgrid[0:9, 0:6].T.reshape(-1, 2)*24
        rng = np.random.default_rng(6)
        observations, objects = [], []
        for _ in range(20):
            points, _ = cv2.projectPoints(obj, rng.uniform(-.4, .4, 3),
                                          np.array([rng.uniform(-200, 100), rng.uniform(-120, 70), rng.uniform(550, 850)]), k, c.d)
            observations.append(points.astype(np.float32))
            objects.append(obj.copy())
        result = fit_camera(objects, observations, c.size)
        self.assertEqual(result['model'], 'brown_conrady_4')
        self.assertEqual(len(result['dist_coeffs']), 4)
        self.assertLess(result['rms_reprojection_error_px'], .001)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'camera.json'
            path.write_text(json.dumps(result))
            loaded = Camera.load(path)
            self.assertEqual(loaded.d[4], 0)

    def test_chessboard_straightness(self):
        squares = (np.indices((7, 10)).sum(axis=0)%2*255).astype(np.uint8)
        image = np.pad(np.repeat(np.repeat(squares, 40, axis=0), 40, axis=1), 60, constant_values=255)
        report = chessboard_straightness(image)
        self.assertLess(report['weighted_rms_px'], .1)

    def test_equalize_constant_image(self):
        image = np.full((30, 40, 3), 100, np.uint8)
        np.testing.assert_array_equal(enhance_image(image, 'equalize')[0], image)

    def test_video_replay(self):
        import cv2
        c = camera()
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'source.avi'
            writer = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*'MJPG'), 30, c.size)
            self.assertTrue(writer.isOpened())
            for i in range(8):
                writer.write(np.full((60, 80, 3), 30+i*10, dtype=np.uint8))
            writer.release()
            result = process_video(path, c, [(0, View()), (3, View(angle=15, border='crop-resize'))], Path(tmp)/'out')
            self.assertEqual(result['frames'], 8)
            self.assertEqual([r['frame'] for r in result['commands_applied']], [0, 3])
            reader = cv2.VideoCapture(str(Path(tmp)/'out'/'corrected.avi'))
            try:
                self.assertEqual(int(reader.get(cv2.CAP_PROP_FRAME_COUNT)), 8)
                ok, image = reader.read()
                self.assertTrue(ok)
                self.assertEqual(image.shape[:2], (60, 80))
            finally:
                reader.release()


if __name__ == '__main__':
    unittest.main()
