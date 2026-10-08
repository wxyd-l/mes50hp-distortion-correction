from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from compare_frame import load_actual,compare_pixels,compare_package,swap_red_blue,read_memh
from prepare_package import prepare,rgb_from_565
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'algorithm'))
from undistort import Camera,export_grid


class CompareFrameTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        self.pixels=np.array([[0xf800,0x07e0,0x001f],[0xffff,0x8410,0x0000]],np.uint16)
        self.valid=np.ones((2,3),bool)

    def tearDown(self):self.tmp.cleanup()

    def test_exact_and_known_single_pixel_error(self):
        row=compare_pixels(self.pixels,self.pixels,self.valid)
        self.assertTrue(row['exact_match']);self.assertIsNone(row['mismatch_bounding_box_xywh'])
        actual=self.pixels.copy();actual[1,1]^=1
        row=compare_pixels(self.pixels,actual,self.valid)
        self.assertEqual(row['mismatched_pixels'],1);self.assertEqual(row['mismatch_bounding_box_xywh'],[1,1,1,1])
        self.assertEqual(row['channels']['B5']['max_absolute_error_codes'],1)
        self.assertEqual(row['first_mismatches'][0]['address'],4)

    def test_color_byte_and_flip_hypotheses_do_not_correct(self):
        candidates=(('swap_red_blue',swap_red_blue(self.pixels)),
                    ('swap_word_bytes',self.pixels.byteswap()),('horizontal_flip',self.pixels[:,::-1]),
                    ('vertical_flip',self.pixels[::-1,:]),('rotate_180',self.pixels[::-1,::-1]))
        for hypothesis,actual in candidates:
            row=compare_pixels(self.pixels,actual,self.valid)
            self.assertFalse(row['exact_match'])
            self.assertTrue(any(v['hypothesis']==hypothesis and v['exact_match_if_applied'] for v in row['diagnostic_hypotheses']))

    def test_invalid_region_black_mismatch(self):
        expected=self.pixels.copy();expected[0,0]=0;valid=self.valid.copy();valid[0,0]=False
        row=compare_pixels(expected,self.pixels,valid)
        self.assertEqual(row['invalid_region_nonblack_pixels'],1)
        self.assertEqual(row['valid_region_mismatched_pixels'],0)

    def test_raw_endian_stride_and_bgr(self):
        for endian in ('little','big'):
            packed=swap_red_blue(self.pixels).astype('<u2' if endian=='little' else '>u2')
            path=self.root/'frame.raw';path.write_bytes(b''.join(row.tobytes()+b'\xff\xee' for row in packed))
            np.testing.assert_array_equal(load_actual(path,(3,2),'raw565','bgr565',endian,8),self.pixels)
            path.write_bytes(path.read_bytes()[:-2])
            np.testing.assert_array_equal(load_actual(path,(3,2),'raw565','bgr565',endian,8),self.pixels)

    def test_raw_rejects_ambiguous_or_wrong_lengths(self):
        path=self.root/'frame.raw';path.write_bytes(self.pixels.tobytes())
        for kwargs in ({},{'pixel_order':'rgb565'},{'pixel_order':'rgb565','byte_order':'little','stride_bytes':5}):
            with self.assertRaises(ValueError):load_actual(path,(3,2),'raw565',**kwargs)
        path.write_bytes(self.pixels.tobytes()+b'\0\0')
        with self.assertRaises(ValueError):load_actual(path,(3,2),'raw565','rgb565','little')

    def test_memh_strict_shape_and_explicit_order(self):
        path=self.root/'frame.memh';path.write_text(''.join(f'{int(v):04x}\n' for v in self.pixels.flat))
        np.testing.assert_array_equal(load_actual(path,(3,2),'memh','rgb565'),self.pixels)
        with self.assertRaises(ValueError):load_actual(path,(3,2),'memh')
        path.write_text('f800\n@0010\n')
        with self.assertRaises(ValueError):read_memh(path,6)

    def test_png_lossless_roundtrip_and_option_rejection(self):
        path=self.root/'frame.png';Image.fromarray(rgb_from_565(self.pixels)).save(path)
        np.testing.assert_array_equal(load_actual(path,(3,2),'png'),self.pixels)
        with self.assertRaises(ValueError):load_actual(path,(3,2),'png','bgr565')
        with self.assertRaises(ValueError):load_actual(path,(4,2),'png')
        rgba=np.dstack((rgb_from_565(self.pixels),np.zeros((2,3),np.uint8)))
        Image.fromarray(rgba).save(path)
        with self.assertRaises(ValueError):load_actual(path,(3,2),'png')

    def test_package_artifacts_and_input_protection(self):
        camera=Camera((3,2),[[3,0,1],[0,3,.5],[0,0,1]],np.zeros(5))
        lut=self.root/'lut';package=self.root/'package';image=self.root/'source.png'
        export_grid(camera,lut,2,8);Image.fromarray(rgb_from_565(self.pixels)).save(image)
        prepare(lut,image,package)
        report=compare_package(package,package/'expected_rgb565.memh',self.root/'comparison','memh','rgb565')
        self.assertTrue(report['exact_match']);self.assertTrue((self.root/'comparison/mismatch_mask.png').exists())
        with self.assertRaises(ValueError):compare_package(package,image,package/'diagnostic','png')
        with self.assertRaises(ValueError):
            compare_package(package,self.root/'comparison/actual_rgb565.png',self.root/'comparison','png')
        (package/'expected_rgb565.memh').write_text('0000\n'*6)
        with self.assertRaisesRegex(ValueError,'checksum'):compare_package(package,image,self.root/'bad','png')


if __name__=='__main__':unittest.main()
