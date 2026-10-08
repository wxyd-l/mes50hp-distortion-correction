from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from inspect_calibration import inspect


def chessboard(size=(640,480),cell=32,origin=(100,100),board=(9,6)):
    image=np.full((size[1],size[0]),210,np.uint8)
    x,y=origin
    for row in range(board[1]+1):
        for col in range(board[0]+1):
            image[y+row*cell:y+(row+1)*cell,x+col*cell:x+(col+1)*cell]=20 if (row+col)%2==0 else 245
    return image


class InspectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        self.frames=self.root/'frames';self.frames.mkdir()

    def tearDown(self):self.tmp.cleanup()

    def test_actual_detector_counts_54_inner_corners(self):
        Image.fromarray(chessboard()).save(self.frames/'棋盘.png')
        result=inspect(self.frames,self.root/'report')
        self.assertEqual(result['detected_frames'],1)
        self.assertEqual(result['frames'][0]['inner_corner_count'],54)
        self.assertEqual(result['image_size'],[640,480])
        self.assertTrue((self.root/'report'/result['frames'][0]['overlay']).exists())
        self.assertNotIn('camera_matrix',result)
        self.assertIn('current_calibration_tool_requires_at_least_8_detected_frames',result['warnings'])

    def test_grid_counts_frames_not_corners(self):
        Image.fromarray(chessboard()).save(self.frames/'a.png')
        Image.fromarray(chessboard(origin=(200,180))).save(self.frames/'b.png')
        result=inspect(self.frames,self.root/'report')
        counts=np.array(result['grid_4x4_frames_with_corners'])
        self.assertGreater(counts.sum(),2);self.assertLessEqual(counts.max(),2)
        self.assertGreater(result['centroid_spread_normalized'][0],.1)

    def test_blank_unreadable_and_user_blur_warning(self):
        Image.fromarray(np.full((480,640),128,np.uint8)).save(self.frames/'blank.png')
        (self.frames/'broken.png').write_bytes(b'not an image')
        result=inspect(self.frames,self.root/'report',min_laplacian_variance=1)
        self.assertEqual(result['detected_frames'],0);self.assertIsNone(result['corner_bounds_normalized'])
        row=next(r for r in result['frames'] if r['readable'])
        self.assertIn('below_user_blur_indicator_threshold',row['warnings'])
        self.assertFalse(next(r for r in result['frames'] if not r['readable'])['detected'])

    def test_mixed_resolution_rejected_before_output(self):
        Image.fromarray(chessboard()).save(self.frames/'a.png')
        Image.new('L',(320,240)).save(self.frames/'b.png')
        with self.assertRaisesRegex(ValueError,'mixed'):inspect(self.frames,self.root/'report')
        self.assertFalse((self.root/'report').exists())

    def test_input_directory_preserved_and_illegal_options(self):
        Image.fromarray(chessboard()).save(self.frames/'a.png')
        original=(self.frames/'a.png').read_bytes()
        for out,board,threshold in ((self.frames,(9,6),None),(self.frames/'nested',(9,6),None),
                                    (self.root/'report',(1,6),None),(self.root/'report',(9,6),float('nan'))):
            with self.assertRaises(ValueError):inspect(self.frames,out,board,min_laplacian_variance=threshold)
        self.assertEqual((self.frames/'a.png').read_bytes(),original)
        with self.assertRaisesRegex(ValueError,'no matching'):inspect(self.frames,self.root/'report',pattern='*.jpg')


if __name__=='__main__':unittest.main()
