"""Independent 3D projection, homography gauge, and fixed-point geometry tests."""
import copy
import unittest
import cv2
import numpy as np

from software.geometry import pose_config, projective_parameters, rotation_source_from_output
from software.reference import (fixed_map, fixed_parameters, float_map,
                                normalized_homography, opencv_map, synthetic_config)


class GeometryTests(unittest.TestCase):
    def test_pose_against_direct_3d_projection(self):
        c = synthetic_config(96, 64)
        c = pose_config(c, yaw_degrees=13, pitch_degrees=-9, roll_degrees=7)
        u, v = np.meshgrid(np.arange(96), np.arange(64))
        k = np.array(c["camera_matrix"])
        rays = np.stack([(u-k[0,2])/k[0,0], (v-k[1,2])/k[1,1], np.ones_like(u)], -1)
        rotation = rotation_source_from_output(13, -9, 7)
        # cv2.projectPoints independently performs 3D perspective division and distortion.
        projected, _ = cv2.projectPoints(rays.reshape(-1,3), cv2.Rodrigues(rotation)[0],
                                        np.zeros(3), k, np.r_[c["distortion"], 0.])
        x, y = float_map(c)
        np.testing.assert_allclose(np.stack([x,y], -1), projected.reshape(64,96,2), atol=1e-10)
        ox, oy = opencv_map(c)
        np.testing.assert_allclose(x, ox, atol=1e-5, rtol=0)
        np.testing.assert_allclose(y, oy, atol=1e-5, rtol=0)
        qx, qy = fixed_map(c)
        self.assertLess(np.max(np.abs(qx/65536-x)), .001)
        self.assertLess(np.max(np.abs(qy/65536-y)), .001)
        # Removing division must visibly fail: this prevents an affine-only implementation passing.
        h = normalized_homography(c)
        wrong = copy.deepcopy(c)
        wrong["output_to_ideal"] = np.asarray(c["output_to_ideal"])[:2].tolist()
        wx, wy = float_map(wrong)
        self.assertGreater(np.max(np.abs(np.stack([x-wx,y-wy]))), 1.)
        self.assertGreater(np.max(np.abs(h[2,:2])), 0.)

    def test_affine_backward_compatibility_and_17_words(self):
        c = synthetic_config()
        self.assertEqual(len(fixed_parameters(c)), 14)
        p = projective_parameters(c)
        self.assertEqual(len(p), 17)
        self.assertEqual(list(p)[-3:], ["a20", "a21", "a22"])
        qx,qy = fixed_map(c)
        c["output_to_ideal"] = np.eye(3).tolist()
        x,y = fixed_map(c)
        np.testing.assert_array_equal(x,qx)
        np.testing.assert_array_equal(y,qy)

    def test_negative_homography_scale_and_signed_quotients(self):
        c = pose_config(synthetic_config(), yaw_degrees=-11, pitch_degrees=6)
        c["projective_positive_depth"] = False
        x,y = float_map(c)
        qx,qy = fixed_map(c)
        c["output_to_ideal"] = (-np.asarray(c["output_to_ideal"])).tolist()
        nx,ny = float_map(c)
        np.testing.assert_allclose(nx,x,atol=1e-12)
        np.testing.assert_allclose(ny,y,atol=1e-12)
        nqx,nqy = fixed_map(c)
        # Arithmetic shifts before division round negative homogeneous terms down.
        self.assertLess(np.max(np.abs(nqx-qx))/65536, .001)
        self.assertLess(np.max(np.abs(nqy-qy))/65536, .001)

    def test_horizon_and_nonpositive_pose_depth_rejected(self):
        c = synthetic_config(16,12)
        c["output_to_ideal"] = [[1,0,0],[0,1,0],[1,0,-7.5]]
        with self.assertRaisesRegex(ValueError, "horizon"): float_map(c)
        with self.assertRaisesRegex(ValueError, "horizon"): fixed_map(c)
        with self.assertRaisesRegex(ValueError, "behind"): pose_config(synthetic_config(), yaw_degrees=180)

    def test_1080p_pose_precision(self):
        c = pose_config(synthetic_config(1920,1080), yaw_degrees=15, pitch_degrees=-10, roll_degrees=8)
        x,y = float_map(c)
        qx,qy = fixed_map(c)
        self.assertLess(np.max(np.abs(qx/65536-x)), .02)
        self.assertLess(np.max(np.abs(qy/65536-y)), .02)


if __name__ == "__main__":
    unittest.main()
