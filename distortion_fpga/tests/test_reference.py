"""Algorithm tests with independent OpenCV maps and hand-computed edge cases."""
import copy
import tempfile
import unittest
from pathlib import Path

import numpy as np
import cv2

from software.calibrate import calibrate_images
from software.cli import export
from software.reference import (bilinear_fixed, bilinear_float, compare, fixed_map,
                                fixed_parameters, float_map, opencv_map,
                                synthetic_config, synthetic_image, validate)


class ReferenceTests(unittest.TestCase):
    def test_calibration_cli_backend_on_synthetic_projected_chessboards(self):
        # This verifies the detection/solver path only. It is not a real calibration.
        columns,rows,square = 9,6,.04
        yy,xx = np.indices((700,1000))
        board = (((xx//100+yy//100)%2)*255).astype(np.uint8)
        source = np.float32([[0,0],[999,0],[999,699],[0,699]])
        corners = np.float32([[-square,-square,0],[columns*square,-square,0],
                              [columns*square,rows*square,0],[-square,rows*square,0]])
        k = np.float64([[700,0,320],[0,710,240],[0,0,1]])
        with tempfile.TemporaryDirectory() as temp:
            paths=[]
            for i in range(12):
                r = np.float64([-.25+.10*(i%4),-.2+.17*(i%3),-.12+.08*(i%4)])
                t = np.float64([-.16+.035*(i%3-1),-.10+.025*(i%4-1.5),.9+.05*(i%3)])
                target,_ = cv2.projectPoints(corners,r,t,k,np.zeros(5))
                transform = cv2.getPerspectiveTransform(source,target.reshape(4,2))
                image = cv2.warpPerspective(board,transform,(640,480),borderValue=180)
                path=Path(temp)/f"SYNTHETIC_TEST_ONLY_{i:02d}.png"
                cv2.imwrite(str(path),image)
                paths.append(path)
            config=calibrate_images(paths,columns,rows,square)
            self.assertEqual(config["validation"]["training_views"],9)
            self.assertEqual(config["validation"]["held_out_views"],3)
            self.assertLess(config["validation"]["training_rms_pixels"],.5)
            self.assertEqual(len(config["distortion"]),4)
            self.assertLess(abs(config["camera_matrix"][0][0]-700),25)

    def test_identity_retains_last_row_and_column(self):
        c = synthetic_config(32,24)
        c["camera_matrix"] = [[32,0,16],[0,32,12],[0,0,1]]
        c["distortion"] = [0,0,0,0]
        image = synthetic_image(32,24)
        x,y = fixed_map(c)
        xx,yy = np.meshgrid(np.arange(32),np.arange(24))
        np.testing.assert_array_equal(x,xx*65536)
        np.testing.assert_array_equal(y,yy*65536)
        np.testing.assert_array_equal(bilinear_fixed(image,x,y),image)

    def test_opencv_independent_map_with_each_coefficient_and_affine(self):
        for index in range(4):
            c = synthetic_config(96,64)
            c["distortion"] = [0,0,0,0]
            c["distortion"][index] = [-.2,.07,.013,-.019][index]
            c["output_to_ideal"] = [[.97,-.14,5],[.14,.97,-3]]
            a,b = float_map(c)
            x,y = opencv_map(c)
            np.testing.assert_allclose(a,x,atol=8e-6,rtol=0)
            np.testing.assert_allclose(b,y,atol=8e-6,rtol=0)

    def test_known_tangential_direction(self):
        c = synthetic_config(3,3)
        c["camera_matrix"] = [[1,0,1],[0,1,1],[0,0,1]]
        c["distortion"] = [0,0,.125,.0625]
        x,y = float_map(c)
        self.assertAlmostEqual(x[1,2],2.1875)
        self.assertAlmostEqual(y[1,2],1.125)
        self.assertAlmostEqual(x[2,1],1.0625)
        self.assertAlmostEqual(y[2,1],2.375)

    def test_bilinear_rounding_and_partial_border(self):
        image = np.array([[0,100],[200,255]],dtype=np.uint8)
        qx = np.array([[32768,-32768,65536]],dtype=np.int64)
        qy = np.array([[32768,0,65536]],dtype=np.int64)
        np.testing.assert_array_equal(bilinear_fixed(image,qx,qy),[[139,0,255]])
        image[0,0] = 100
        self.assertEqual(int(bilinear_fixed(image,qx,qy)[0,1]),50)
        np.testing.assert_array_equal(bilinear_float(image,qx/65536,qy/65536),bilinear_fixed(image,qx,qy))

    def test_fixed_error_at_1080p_and_affine(self):
        c = synthetic_config(1920,1080)
        c["output_to_ideal"] = [[.9848,-.17365,108],[.17365,.9848,-158]]
        x,y = fixed_map(c)
        a,b = float_map(c)
        self.assertLess(float(np.max(np.abs(x/65536-a))),.01)
        self.assertLess(float(np.max(np.abs(y/65536-b))),.01)

    def test_overflow_rejected_before_export(self):
        c = synthetic_config(16,12)
        c["distortion"] = [127,127,0,0]
        c["camera_matrix"] = [[1,0,0],[0,1,0],[0,0,1]]
        with tempfile.TemporaryDirectory() as temp:
            dst = Path(temp)/"bad"
            with self.assertRaisesRegex(ValueError,"overflow"):
                export(c,dst)
            self.assertFalse(dst.exists())

    def test_invalid_models_and_resolution_are_rejected(self):
        for key,value in (("distortion",[0,0,0,0,.1]),("output_to_ideal",[[0,0,0],[0,0,0]])):
            c = synthetic_config()
            c[key] = value
            with self.assertRaises(ValueError): validate(c)
        c = synthetic_config()
        c["distortion"][0] = float("nan")
        with self.assertRaises(ValueError): validate(c)
        with self.assertRaises(ValueError): compare(synthetic_config(),synthetic_image(32,24))

    def test_export_provenance_formats_and_vectors(self):
        c = synthetic_config(16,12)
        with tempfile.TemporaryDirectory() as temp:
            m = export(c,temp,synthetic_image(16,12))
            self.assertEqual(m["provenance"]["kind"],"synthetic")
            self.assertEqual(m["formats"]["a"],"Q4.28")
            self.assertEqual(len((Path(temp)/"parameters.mem").read_text().splitlines()),14)
            self.assertEqual(len((Path(temp)/"coordinates.mem").read_text().splitlines()),192)


if __name__ == "__main__":
    unittest.main()
