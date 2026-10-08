from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from pipeline import write_json
from rotation_experiment import roi_metrics,run


class RotationExperimentTests(unittest.TestCase):
    def test_pixel_center_area_and_zoom(self):
        metrics=roi_metrics({'valid_roi_on_base_canvas':[10,5,17,10]},(33,19))
        self.assertEqual(metrics['retained_base_canvas_area_fraction'],.25)
        self.assertEqual(metrics['output_to_roi_zoom_x'],2)
        self.assertEqual(metrics['output_to_roi_zoom_y'],2)

    def test_all_eight_cases_and_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary)
            camera=directory/'camera.json';source=directory/'input.png'
            write_json(camera,{'model':'brown_conrady_4','image_size':[64,48],
                       'camera_matrix':[[50,0,31.5],[0,50,23.5],[0,0,1]],'dist_coeffs':[0,0,0,0]})
            y,x=np.indices((48,64));array=np.stack([x*3,y*4,x+y],axis=-1).astype(np.uint8)
            Image.fromarray(array).save(source)
            result=run(camera,source,directory/'result',step=8)
            self.assertEqual(len(result['cases']),8)
            for case in result['cases']:
                folder=directory/'result'/case['directory']
                for name in ('corrected.png','valid_mask.png','reference_maps.npz','grid.json','grid.memh','view.json','report.json'):
                    self.assertTrue((folder/name).is_file())
                self.assertEqual(case['output_size'],[64,48])
                if case['border']=='crop-resize':self.assertEqual(case['invalid_pixels'],0)
            np.testing.assert_array_equal(np.asarray(Image.open(directory/'result'/'angle0_keep'/'corrected.png')),array)
            self.assertTrue((directory/'result'/'comparison.png').is_file())
            self.assertTrue((directory/'result'/'input_vs_corrected.png').is_file())
            self.assertTrue((directory/'result'/'summary.json').is_file())

    def test_invalid_angle_lists(self):
        for angles in ([],[0,0],[float('nan')],[float('inf')]):
            with self.assertRaisesRegex(ValueError,'angles'):
                run(Path('unused'),Path('unused'),Path('unused'),angles=angles)


if __name__=='__main__':
    unittest.main()
