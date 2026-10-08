import json
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from build_delivery import build,verify


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        (self.root/'algorithm').mkdir();(self.root/'rtl/src').mkdir(parents=True)
        (self.root/'rtl/out').mkdir()
        (self.root/'README.md').write_text('test project')
        (self.root/'algorithm/model.py').write_text('x=1')
        (self.root/'rtl/src/core.v').write_text('module core;endmodule')
        (self.root/'.runtime').mkdir();(self.root/'.runtime/private.txt').write_text('not included')

    def tearDown(self):self.tmp.cleanup()

    def test_scoped_archive_and_verified_bytes(self):
        (self.root/'algorithm/examples').mkdir()
        (self.root/'algorithm/examples/camera_real.json').write_text('not automatically shared')
        destination=self.root/'out/bundle.zip';result=build(self.root,destination)
        self.assertTrue(result['verified']);self.assertEqual(result['files'],3)
        with zipfile.ZipFile(destination) as archive:
            self.assertNotIn('.runtime/private.txt',archive.namelist())
            self.assertNotIn('algorithm/examples/camera_real.json',archive.namelist())
            self.assertIn('rtl/src/core.v',archive.namelist())
        self.assertTrue(verify(destination)['verified'])

    def test_existing_archive_is_preserved(self):
        destination=self.root/'bundle.zip';destination.write_bytes(b'user archive')
        with self.assertRaises(FileExistsError):build(self.root,destination)
        self.assertEqual(destination.read_bytes(),b'user archive')

    def test_stale_report_not_packaged(self):
        (self.root/'rtl/out/regression.json').write_text(json.dumps([{'passed':True,'source_sha256':{'src/core.v':'wrong'}}]))
        result=build(self.root,self.root/'bundle.zip')
        self.assertEqual(result['excluded_stale_reports'],['rtl/out/regression.json'])
        self.assertFalse(result['included_current_simulation_reports'])

    def test_tamper_and_unsafe_paths_rejected(self):
        destination=self.root/'bad.zip'
        with zipfile.ZipFile(destination,'w') as archive:
            archive.writestr('a.txt','wrong')
            archive.writestr('delivery_manifest.json',json.dumps({'schema':'fpga_algorithm_delivery_v1','files':{'a.txt':{'bytes':5,'sha256':'wrong'}}}))
        with self.assertRaisesRegex(ValueError,'checksum'):verify(destination)
        with zipfile.ZipFile(destination,'w') as archive:archive.writestr('../outside','bad')
        with self.assertRaisesRegex(ValueError,'unsafe'):verify(destination)

    def test_formula_sources_and_algorithm_hash_are_packaged(self):
        (self.root/'rtl/formula').mkdir()
        (self.root/'rtl/formula/mapper.sv').write_text('module mapper;endmodule')
        (self.root/'rtl/out/formula-test').mkdir()
        row={'passed':True,'source_sha256':{'src/core.v':hashlib.sha256((self.root/'rtl/src/core.v').read_bytes()).hexdigest()},
             'algorithm_source_sha256':{'model.py':hashlib.sha256((self.root/'algorithm/model.py').read_bytes()).hexdigest()}}
        (self.root/'rtl/out/formula-test/result.json').write_text(json.dumps(row))
        result=build(self.root,self.root/'formula.zip')
        self.assertEqual(result['included_current_simulation_reports'],['rtl/out/formula-test/result.json'])
        with zipfile.ZipFile(self.root/'formula.zip') as archive:self.assertIn('rtl/formula/mapper.sv',archive.namelist())

    def test_stale_algorithm_excludes_formula_report(self):
        (self.root/'rtl/out/formula-test').mkdir()
        row={'passed':True,'source_sha256':{'src/core.v':hashlib.sha256((self.root/'rtl/src/core.v').read_bytes()).hexdigest()},
             'algorithm_source_sha256':{'model.py':'stale'}}
        (self.root/'rtl/out/formula-test/result.json').write_text(json.dumps(row))
        result=build(self.root,self.root/'formula.zip')
        self.assertEqual(result['excluded_stale_reports'],['rtl/out/formula-test/result.json'])


if __name__=='__main__':unittest.main()
