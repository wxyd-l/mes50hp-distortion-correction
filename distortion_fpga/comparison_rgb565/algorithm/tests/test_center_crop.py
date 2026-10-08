from pathlib import Path
import importlib.util
import sys
import tempfile
import unittest

import numpy as np

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from geometry import View,Mapping,centered_valid_roi,plan_fixed_crop,crop_valid_coordinates
from pipeline import apply_crop_plan,process_video
from crop_experiment import run as run_experiment
from undistort import Camera


def camera(size=(80,60),d=None):
    return Camera(size,[[70,0,(size[0]-1)/2],[0,71,(size[1]-1)/2],[0,0,1]],
                  [-.15,.025,.001,-.001,0] if d is None else d)


class CenterCropTests(unittest.TestCase):
    def test_full_mask_identity(self):
        self.assertEqual(centered_valid_roi(np.ones((5,7),bool),(7,5)),(0.,0.,7.,5.))
        m=Mapping(camera(d=np.zeros(5)),View(border='crop-center'))
        self.assertEqual(m.roi,(0.,0.,80.,60.))

    def test_reject_empty_center_or_tiny_mask(self):
        for mask in (np.zeros((5,7),bool),np.ones((1,7),bool)):
            with self.assertRaises(ValueError):centered_valid_roi(mask,(7,5))
        mask=np.ones((5,7),bool);mask[2,3]=False
        with self.assertRaisesRegex(ValueError,'centered'):centered_valid_roi(mask,(7,5))

    def test_interior_hole_not_only_corners(self):
        mask=np.ones((7,9),bool);mask[3,2]=False
        roi=centered_valid_roi(mask,(9,7));x,y,w,h=roi
        self.assertGreaterEqual(x,3-1e-12)
        self.assertTrue(mask[int(np.floor(y)):int(np.ceil(y+h-1))+1,
                             int(np.floor(x)):int(np.ceil(x+w-1))+1].all())

    def test_maximum_against_discrete_scale_brute_force(self):
        rng=np.random.default_rng(24)
        for _ in range(30):
            mask=rng.random((7,9))>.2;mask[2:5,3:6]=True
            roi=centered_valid_roi(mask,(9,7));scale=(roi[2]-1)/8
            best=0.
            for candidate in np.linspace(1/6,1,1001):
                x0=int(np.floor(4-4*candidate));x1=int(np.ceil(4+4*candidate))
                y0=int(np.floor(3-3*candidate));y1=int(np.ceil(3+3*candidate))
                if mask[y0:y1+1,x0:x1+1].all():best=candidate
            self.assertGreaterEqual(scale+1e-12,best)
            self.assertLessEqual(scale,best+1/1000+1e-12)

    def test_center_and_source_margin_all_angles(self):
        c=camera()
        for angle in (-30,-20,-10,0,10,20,30):
            m=Mapping(c,View(angle=angle,border='crop-center',crop_safety_px=.5))
            x,y,w,h=m.roi
            self.assertAlmostEqual(x+(w-1)/2,(c.size[0]-1)/2)
            self.assertAlmostEqual(y+(h-1)/2,(c.size[1]-1)/2)
            self.assertAlmostEqual((w-1)/(h-1),79/59)
            self.assertTrue(crop_valid_coordinates(*m.dense(),c.size,.5).all())

    def test_fixed_plan_immutable_roi_across_commands(self):
        c=camera();views=[View(angle=a) for a in (-30,-20,-10,0,10,20,30)]
        plan=plan_fixed_crop(c,views,.5)
        commands=apply_crop_plan(c,list(enumerate(views)),plan)
        rois=[]
        for _,view in commands:
            m=Mapping(c,view);rois.append(m.roi)
            self.assertTrue(crop_valid_coordinates(*m.dense(),c.size,.5).all())
        self.assertTrue(all(roi==tuple(plan['fixed_roi']) for roi in rois))

    def test_plan_mismatch_and_unsafe_unlisted_pose(self):
        c=camera();plan=plan_fixed_crop(c,[View(angle=0),View(angle=20)])
        with self.assertRaisesRegex(ValueError,'camera'):
            apply_crop_plan(camera(d=[-.2,.01,0,0,0]),[(0,View())],plan)
        with self.assertRaises(ValueError):apply_crop_plan(c,[(0,View(yaw=180))],plan)

    def test_invalid_fixed_roi_and_aspect(self):
        for kwargs in ({'border':'crop-fixed'},{'border':'crop-fixed','fixed_roi':1},
                       {'fixed_roi':[0,0,80,60]},{'crop_safety_px':-1}):
            with self.assertRaises(ValueError):View(**kwargs)
        for roi in ([0,0,80,50],[1,0,80,60]):
            with self.assertRaises(ValueError):Mapping(camera(),View(border='crop-fixed',fixed_roi=roi))

    def test_fixed_crop_never_silently_shrinks(self):
        with self.assertRaisesRegex(ValueError,'safe'):
            Mapping(camera(),View(angle=30,border='crop-fixed',fixed_roi=[0,0,80,60]))

    def test_no_common_view_and_invalid_safety(self):
        c=camera()
        for views,margin in (([],.5),([View()],float('nan')),([View()],100),([View(yaw=180)],.5)):
            with self.assertRaises(ValueError):plan_fixed_crop(c,views,margin)

    def test_experiment_artifacts_preserve_center_and_fixed_roi(self):
        import json
        from PIL import Image
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);c=camera()
            source=root/'source.png';cp=root/'camera.json'
            cp.write_text(json.dumps({'model':'brown_conrady_5','image_size':list(c.size),
                'camera_matrix':c.k.tolist(),'dist_coeffs':c.d.tolist()}))
            Image.fromarray(np.full((60,80,3),128,np.uint8)).save(source)
            result=run_experiment(cp,source,root/'result',angles=(0,20),plan_angles=(-20,0,20))
            self.assertEqual(len(result['cases']),8)
            for case in result['cases']:
                if case['mode']!='keep':self.assertEqual(case['invalid_pixels'],0)
                if case['mode'] in ('crop-center','crop-fixed'):self.assertLess(case['center_offset_px'],1e-10)
                if case['mode']=='crop-fixed':self.assertEqual(case['roi'],result['plan']['fixed_roi'])
                self.assertTrue((root/'result'/case['directory']/'grid.memh').is_file())
            self.assertTrue((root/'result'/'comparison.png').is_file())

    @unittest.skipUnless(importlib.util.find_spec('cv2'),'OpenCV unavailable: video integration not tested')
    def test_fixed_plan_video_replay(self):
        import cv2
        c=camera();plan=plan_fixed_crop(c,[View(),View(angle=20)])
        commands=apply_crop_plan(c,[(0,View()),(3,View(angle=20))],plan)
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);source=root/'source.avi'
            writer=cv2.VideoWriter(str(source),cv2.VideoWriter_fourcc(*'MJPG'),30,c.size)
            self.assertTrue(writer.isOpened())
            try:
                for i in range(8):writer.write(np.full((60,80,3),50+i*10,np.uint8))
            finally:writer.release()
            report=process_video(source,c,commands,root/'output')
            self.assertEqual(report['frames'],8)
            self.assertEqual([e['frame'] for e in report['commands_applied']],[0,3])
            for entry in report['commands_applied']:
                self.assertEqual(entry['mapping']['valid_roi_on_base_canvas'],plan['fixed_roi'])
                self.assertEqual(entry['mapping']['view']['border'],'crop-fixed')
            capture=cv2.VideoCapture(str(root/'output'/'corrected.avi'))
            try:
                self.assertEqual(int(capture.get(cv2.CAP_PROP_FRAME_COUNT)),8)
                ok,frame=capture.read();self.assertTrue(ok);self.assertEqual(frame.shape[:2],(60,80))
            finally:capture.release()


if __name__=='__main__':unittest.main()
