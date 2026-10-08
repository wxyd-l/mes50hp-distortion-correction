import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from compare_mappers import (Camera,Mapping,View,compare,formula_package,render_coordinates,
                             synthetic_pattern,rgb_to_565)
from reference import pixel_from_point
from run_formula_sim import validate_package,read_words


class FormulaCompareTests(unittest.TestCase):
    def mapping(self):
        return Mapping(Camera((17,13),[[16,0,8],[0,16,6],[0,0,1]],[0]*5))

    def test_coordinate_render_matches_scalar(self):
        rng=np.random.default_rng(432)
        source=rng.integers(0,65536,(13,17),dtype=np.uint16)
        for fraction in (8,16):
            x=rng.integers(-65536,17*(1<<fraction),(9,11),dtype=np.int64)
            y=rng.integers(-65536,13*(1<<fraction),(9,11),dtype=np.int64)
            result,mask=render_coordinates(source,x,y,fraction)
            for i,j in np.ndindex(result.shape):
                expected,valid=pixel_from_point(source,int(x[i,j]),int(y[i,j]),fraction)
                self.assertEqual(result[i,j],expected);self.assertEqual(mask[i,j],valid)

    def test_boundary_contract(self):
        source=np.full((3,3),0xffff,np.uint16)
        result,mask=render_coordinates(source,np.array([[-1,2<<16]]),np.array([[0,2<<16]]))
        np.testing.assert_array_equal(result,[[0,0xffff]])
        np.testing.assert_array_equal(mask,[[False,True]])

    def test_render_input_rejection(self):
        source=np.zeros((3,3),np.uint16)
        for x,y,f in (([[0.5]],[[0]],16),([[0]],[[0],[0]],16),([[1<<31]],[[0]],16),([[0]],[[0]],0)):
            with self.assertRaises(ValueError):render_coordinates(source,np.array(x),np.array(y),f)
        with self.assertRaises(ValueError):render_coordinates(np.array([[-1,0],[0,0]]),np.zeros((1,1),int),np.zeros((1,1),int))

    def test_formula_package_integrity(self):
        with tempfile.TemporaryDirectory() as temporary:
            mapping=self.mapping();source=rgb_to_565(synthetic_pattern(mapping.camera.size))
            report,_=formula_package(mapping,source,Path(temporary))
            loaded,oracle=validate_package(Path(temporary))
            self.assertEqual(loaded,report);self.assertEqual(oracle['requests'],17*13*4)
            self.assertEqual(report['invalid_pixels'],0)

    def test_package_tampering_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            mapping=self.mapping();root=Path(temporary)
            formula_package(mapping,rgb_to_565(synthetic_pattern(mapping.camera.size)),root)
            (root/'expected_x.memh').write_text('00000000\n',encoding='ascii')
            with self.assertRaises(ValueError):validate_package(root)

    def test_overflow_fixture_has_no_reads(self):
        with tempfile.TemporaryDirectory() as temporary:
            mapping=self.mapping();root=Path(temporary)
            report,_=formula_package(mapping,rgb_to_565(synthetic_pattern(mapping.camera.size)),root,True)
            _,oracle=validate_package(root)
            self.assertEqual(oracle['requests'],0);self.assertEqual(report['overflow_pixels'],17*13)

    def test_same_input_identity_comparison(self):
        with tempfile.TemporaryDirectory() as temporary:
            mapping=self.mapping()
            report=compare(mapping.camera,View(),Path(temporary))
            for metrics in report['metrics'].values():
                self.assertEqual(metrics['invalid_pixels'],0)
                self.assertEqual(metrics['pixel_mismatches_to_exact_float565'],0)
            self.assertEqual(report['formula_coefficients_bytes'],56)

    def test_unsupported_model_creates_no_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)/'output'
            c=Camera((17,13),[[16,0,8],[0,16,6],[0,0,1]],[0,0,0,0,.001])
            with self.assertRaises(ValueError):compare(c,View(),root)
            self.assertFalse(root.exists())

    def test_word_file_strict_length(self):
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/'words'
            for words in ('0000\n','// comment\n','0000000z\n'):
                path.write_text(words,encoding='ascii')
                with self.assertRaises(ValueError):read_words(path,2,8)

    def test_mask_not_binary_is_rejected_even_with_hash(self):
        with tempfile.TemporaryDirectory() as temporary:
            mapping=self.mapping();root=Path(temporary)
            report,_=formula_package(mapping,rgb_to_565(synthetic_pattern(mapping.camera.size)),root)
            path=root/'expected_valid.memh';path.write_text('2\n'*(17*13),encoding='ascii')
            report['sha256'][path.name]=hashlib.sha256(path.read_bytes()).hexdigest()
            (root/'package.json').write_text(json.dumps(report),encoding='utf-8')
            with self.assertRaises(ValueError):validate_package(root)
