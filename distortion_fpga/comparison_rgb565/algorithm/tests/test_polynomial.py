import sys
import unittest
from pathlib import Path
import numpy as np

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from geometry import Mapping,View
from lens_diagnostics import synthetic_wide_camera
from polynomial import PARAMETER_NAMES,export_parameters,fixed_map,fixed_points,packed_parameters,quantize_parameter,signed32,validate_parameters
from undistort import Camera


class PolynomialTests(unittest.TestCase):
    def camera(self,d=(0,0,0,0,0)):
        return Camera((41,25),[[32,0,20],[0,32,12],[0,0,1]],d)

    def test_identity_exact(self):
        mapping=Mapping(self.camera())
        sx,sy=fixed_map(mapping);v,u=np.indices((25,41))
        np.testing.assert_array_equal(sx,u*65536);np.testing.assert_array_equal(sy,v*65536)

    def test_each_coefficient_against_exact(self):
        for d in ((-.2,0,0,0,0),(0,.04,0,0,0),(0,0,.001,0,0),(0,0,0,-.002,0),(-.2,.04,.001,-.002,0)):
            mapping=Mapping(self.camera(d),View(angle=20,border='crop-center',crop_safety_px=.5))
            sx,sy=fixed_map(mapping);x,y=mapping.dense()
            self.assertLess(np.max(np.hypot(sx/65536-x,sy/65536-y)),.001)

    def test_wide_mapping(self):
        mapping=Mapping(synthetic_wide_camera((81,49)),View(angle=60,border='crop-center',crop_safety_px=.5))
        sx,sy=fixed_map(mapping);x,y=mapping.dense()
        self.assertLess(np.max(np.hypot(sx/65536-x,sy/65536-y)),.001)

    def test_nonzero_k3_rejected(self):
        with self.assertRaises(ValueError):export_parameters(Mapping(self.camera((0,0,0,0,.001))))

    def test_pitch_and_yaw_rejected(self):
        for view in (View(pitch=5),View(yaw=5)):
            with self.assertRaises(ValueError):export_parameters(Mapping(self.camera(),view))

    def test_planar_roll_supported(self):
        mapping=Mapping(self.camera(),View(roll=20,angle=10))
        sx,sy=fixed_map(mapping);x,y=mapping.dense()
        self.assertLess(np.max(np.hypot(sx/65536-x,sy/65536-y)),.001)

    def test_pack_order_and_negative(self):
        p={name:i-7 for i,name in enumerate(PARAMETER_NAMES)}
        packed=packed_parameters(p)
        for i,name in enumerate(PARAMETER_NAMES):self.assertEqual((packed>>(i*32))&0xffffffff,p[name]&0xffffffff)

    def test_parameter_shape_range_and_bool(self):
        p=export_parameters(Mapping(self.camera()))
        for bad in ({**p,'extra':0},{**p,'a00':True},{**p,'k1':1<<31}):
            with self.assertRaises(ValueError):validate_parameters(bad)

    def test_quantize_ties_even(self):
        np.testing.assert_array_equal(quantize_parameter([.5,1.5,-.5,-1.5],0,'test'),[0,2,0,-2])

    def test_quantize_overflow(self):
        for bad in (np.inf,np.nan,1<<31,-(1<<31)-1):
            with self.assertRaises(ValueError):quantize_parameter(bad,0,'test')

    def test_runtime_overflow(self):
        p={name:0 for name in PARAMETER_NAMES};p.update(a02=(1<<31)-1,fx=65536,fy=65536)
        with self.assertRaises(ValueError):fixed_points(p,0,0)

    def test_index_validation(self):
        p=export_parameters(Mapping(self.camera()))
        for index in (-1,65536,.5,np.nan):
            with self.assertRaises(ValueError):fixed_points(p,index,0)

    def test_signed32_limits(self):
        np.testing.assert_array_equal(signed32([-(1<<31),(1<<31)-1],'limits'),[-(1<<31),(1<<31)-1])
        with self.assertRaises(ValueError):signed32(1<<31,'limit')
