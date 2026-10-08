import json
from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from reference import blend, dense_grid, grid_point, load_grid, render, render_fast
from prepare_package import prepare, read_grid, rgb_to_565, rgb_from_565
from generate_gamma import table
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'algorithm'))
from undistort import Camera, export_grid


class IntegerReferenceTests(unittest.TestCase):
    def test_gamma_identity_monotonic_endpoints(self):
        for bits in (5,6):
            maximum=(1 << bits)-1
            self.assertEqual(table(bits,1),list(range(maximum+1)))
            for gamma in (.1,.5,1.8,10):
                values=table(bits,gamma)
                self.assertEqual((values[0],values[-1]),(0,maximum))
                self.assertTrue(all(a<=b for a,b in zip(values,values[1:])))
            self.assertGreater(table(bits,1.8)[maximum//2],maximum//2)

    def test_gamma_invalid_values(self):
        for gamma in (0,-1,.01,11,float('nan'),float('inf')):
            with self.assertRaises(ValueError):table(5,gamma)

    def test_signed_half_rounds_toward_positive_infinity(self):
        self.assertEqual(blend(-1,0,-1,0,128,0,8),0)
        self.assertEqual(blend(-2,-1,-2,-1,128,0,8),-1)

    def test_weights_reject_outside_endpoints(self):
        for value in (-1,257):
            with self.assertRaises(ValueError):
                blend(1,2,3,4,value,0,8)

    def test_rgb_roundtrip_all_codes(self):
        pixels = np.arange(65536,dtype=np.uint16).reshape(256,256)
        np.testing.assert_array_equal(rgb_to_565(rgb_from_565(pixels)),pixels)

    def test_scalar_vs_vectorized_random_and_extreme_coordinates(self):
        rng = np.random.default_rng(1234)
        size=(35,23);xs=np.array([0,8,16,24,32,34]);ys=np.array([0,8,16,22])
        for wf in (8,16):
            for extreme in (False,True):
                if extreme:
                    values=np.array([-(1<<31),(1<<31)-1],dtype=np.int64)
                    qx=values[np.indices((4,6)).sum(axis=0)%2];qy=qx[::-1].copy()
                else:
                    qx=rng.integers(-2048,12000,(4,6),dtype=np.int64)
                    qy=rng.integers(-2048,9000,(4,6),dtype=np.int64)
                grid=(xs,ys,qx,qy);mx,my=dense_grid(grid,size,wf)
                for y in range(size[1]):
                    for x in range(size[0]):
                        self.assertEqual((int(mx[y,x]),int(my[y,x])),grid_point(x,y,grid,size,wf))

    def test_scalar_vs_vectorized_pixels(self):
        rng=np.random.default_rng(22);size=(35,23)
        source=rng.integers(0,65536,(23,35),dtype=np.uint16)
        xs=np.array([0,8,16,24,32,34]);ys=np.array([0,8,16,22])
        u,v=np.meshgrid(xs,ys)
        for frac in (4,8,16):
            grid=load_grid(u+.33*np.sin(v),v-.4,size,8,frac)
            for wf in (8,16):
                expected,mask=render(source,grid,size,frac,wf)
                actual,valid=render_fast(source,grid,size,frac,wf)
                np.testing.assert_array_equal(actual,expected)
                np.testing.assert_array_equal(valid,mask)

    def test_full_hd_identity_coordinates_including_short_cells(self):
        size=(1920,1080);xs=np.append(np.arange(0,1920,32),1919);ys=np.append(np.arange(0,1080,32),1079)
        u,v=np.meshgrid(xs,ys);grid=load_grid(u,v,size,32,8)
        mx,my=dense_grid(grid,size,16)
        np.testing.assert_array_equal(mx,np.broadcast_to(np.arange(1920)*256,(1080,1920)))
        np.testing.assert_array_equal(my,np.broadcast_to(np.arange(1080)[:,None]*256,(1080,1920)))


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory()
        self.root=Path(self.temporary.name)
        self.lut=self.root/'lut';self.output=self.root/'package';self.image=self.root/'source.png'
        self.camera=Camera((35,23),[[29,0,17],[0,30,11],[0,0,1]],[0,0,0,0,0])
        export_grid(self.camera,self.lut,8,8)
        pixels=np.arange(805,dtype=np.uint16).reshape(23,35)
        Image.fromarray(rgb_from_565(pixels)).save(self.image)

    def tearDown(self):
        self.temporary.cleanup()

    def mutate(self,key,value):
        path=self.lut/'grid.json';metadata=json.loads(path.read_text())
        metadata[key]=value;path.write_text(json.dumps(metadata))

    def test_identity_package_is_lossless_and_hashed(self):
        report=prepare(self.lut,self.image,self.output)
        self.assertEqual(report['node_count'],24)
        self.assertEqual(report['invalid_pixels'],0)
        self.assertLess(report['fixed_vs_float_same_grid_max_coordinate_error_px'],1e-12)
        self.assertEqual((self.output/'source_rgb565.memh').read_bytes(),(self.output/'expected_rgb565.memh').read_bytes())
        self.assertEqual(len(report['sha256']['grid.memh']),64)

    def test_wrong_input_size_rejected(self):
        Image.new('RGB',(34,23)).save(self.image)
        with self.assertRaisesRegex(ValueError,'dimensions'):
            prepare(self.lut,self.image,self.output)

    def test_non_power_of_two_grid_rejected(self):
        self.mutate('grid_step',7)
        with self.assertRaisesRegex(ValueError,'power-of-two'):
            read_grid(self.lut)

    def test_axes_mismatch_rejected(self):
        self.mutate('x_nodes',[0,8,16,24,32,35])
        with self.assertRaisesRegex(ValueError,'axes'):
            read_grid(self.lut)

    def test_missing_node_rejected(self):
        path=self.lut/'grid.memh';path.write_text('\n'.join(path.read_text().splitlines()[:-1]))
        with self.assertRaisesRegex(ValueError,'exactly'):
            read_grid(self.lut)

    def test_reverse_mapping_rejected(self):
        self.mutate('mapping_direction','input_to_output')
        with self.assertRaisesRegex(ValueError,'map output'):
            read_grid(self.lut)

    def test_frame_address_overflow_rejected(self):
        self.mutate('input_size',[8192,8192])
        with self.assertRaisesRegex(ValueError,'24-bit'):
            read_grid(self.lut)

    def test_coordinate_overflow_rejected(self):
        self.mutate('input_size',[65535,23]);self.mutate('frac_bits',16)
        with self.assertRaisesRegex(ValueError,'int32'):
            read_grid(self.lut)

    def test_input_directory_overwrite_rejected(self):
        with self.assertRaisesRegex(ValueError,'overwrite'):
            prepare(self.lut,self.image,self.lut)


if __name__=='__main__':
    unittest.main()
