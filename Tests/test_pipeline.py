import json
from pathlib import Path
import sys
import tempfile
import unittest
import cv2
import numpy as np

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from gaze_pipeline import Pipeline, Calibration, linear, encoded, mask_record


class CalibrationTests(unittest.TestCase):
    def record(self,t,quality=1,offset=.02):
        eyes={name:{'quality':quality,'reason':'ok','iris':[50+offset*50,40],
                    'targetUncalibrated':[50,40],'width':50,'radius':10,
                    'basis':[[1,0],[0,1]]} for name in ['left','right']}
        return {'timestamp':t,'eyes':eyes,'pose':{'angles':[0,0,0]}}

    def test_automatic_does_not_learn_gaze_zero(self):
        c=Calibration()
        for i in range(100): c.observe(self.record(i/30),{'camera':'a'})
        self.assertIsNone(c.profile)

    def test_explicit_fixation_requires_time_and_valid_samples(self):
        c=Calibration(); c.command('calibrate',0)
        for i in range(35): c.observe(self.record(i/30),{'camera':'a'})
        self.assertIsNone(c.profile)
        for i in range(35,62): c.observe(self.record(i/30),{'camera':'a'})
        self.assertIsNotNone(c.profile)
        np.testing.assert_allclose(c.offset('left',[0,0,0],{'camera':'a'},.2),[.02,0],atol=1e-6)

    def test_low_quality_timeout_does_not_save(self):
        c=Calibration(); c.command('calibrate',0)
        for i in range(400): c.observe(self.record(i/30,quality=.1),{'camera':'a'})
        self.assertIsNone(c.profile)
        self.assertFalse(c.collecting)

    def test_profile_context_and_pose_mismatch_are_inactive(self):
        c=Calibration(); c.command('calibrate',0)
        for i in range(62): c.observe(self.record(i/30),{'camera':'a'})
        np.testing.assert_array_equal(c.offset('left',[0,0,0],{'camera':'b'},.2),[0,0])
        np.testing.assert_array_equal(c.offset('left',[30,0,0],{'camera':'a'},.2),[0,0])

    def test_unstable_fixation_is_rejected(self):
        c=Calibration(); c.command('calibrate',0)
        for i in range(100): c.observe(self.record(i/30,offset=.15*(-1)**i),{'camera':'a'})
        self.assertIsNone(c.profile)

    def test_save_reload_reset_and_add_pose(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'profile.json'; c=Calibration(p);c.command('calibrate',0)
            for i in range(62): c.observe(self.record(i/30),{'camera':'a'})
            self.assertTrue(p.exists())
            loaded=Calibration(p);self.assertIsNotNone(loaded.profile)
            loaded.command('calibrate-add',3)
            for i in range(62):
                r=self.record(3+i/30);r['pose']['angles']=[10,0,0]
                loaded.observe(r,{'camera':'a'})
            self.assertGreater(len(loaded.profile['samples']),62)
            loaded.command('reset',6);self.assertFalse(p.exists())

    def test_invalid_profile_is_ignored_and_can_be_reset(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'bad.json';path.write_text('{invalid')
            c=Calibration(path)
            self.assertIsNone(c.profile)
            self.assertIn('Invalid profile',c.status)
            c.command('reset',0)
            self.assertFalse(path.exists())

    def test_add_pose_does_not_mix_camera_geometries(self):
        c=Calibration();c.command('calibrate',0)
        for i in range(62):c.observe(self.record(i/30),{'camera':'a'})
        previous=c.profile
        c.command('calibrate-add',3);c.observe(self.record(3.1),{'camera':'b'})
        self.assertFalse(c.collecting)
        self.assertEqual(c.profile,previous)


class RenderingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root=Path(__file__).resolve().parents[1]
        cap=cv2.VideoCapture(str(cls.root/'Assets/test-video-2.mp4'))
        cap.set(cv2.CAP_PROP_POS_FRAMES,108);ok,cls.image=cap.read();cap.release()
        assert ok

    def test_zero_strength_is_pixel_identical(self):
        p=Pipeline(engine='geometry',strength=0)
        try:
            output,r=p.process(self.image,0,0)
            np.testing.assert_array_equal(output,self.image)
        finally: p.close()

    def test_no_face_clears_history_and_passes_through(self):
        p=Pipeline(engine='geometry')
        try:
            p.process(self.image,0,0)
            blank=np.full_like(self.image,120)
            output,r=p.process(blank,1,1/24)
            self.assertEqual(r['status'],'no-face')
            self.assertFalse(p.history)
            self.assertFalse(p.targets)
            np.testing.assert_array_equal(output,blank)
        finally: p.close()

    def test_matched_frame_and_no_changes_outside_eyes(self):
        p=Pipeline(engine='hybrid')
        try:
            output,r=p.process(self.image,117,4.875)
            self.assertEqual(r['frameID'],117);self.assertEqual(r['timestamp'],4.875)
            json.dumps(r,allow_nan=False)
            mask=np.zeros(self.image.shape[:2],np.uint8)
            for e in r['eyes'].values():
                cv2.fillPoly(mask,[np.round(e['contour']).astype(np.int32)],1)
                self.assertIn('targetUncalibrated',e)
                self.assertEqual(e['qualityType'],'heuristic')
            self.assertGreater(np.count_nonzero(output!=self.image),100)
            np.testing.assert_array_equal(output[mask==0],self.image[mask==0])
        finally: p.close()

    def test_duplicate_timestamps_fail_instead_of_reusing_measurements(self):
        p=Pipeline(engine='geometry')
        try:
            p.process(self.image,0,0)
            with self.assertRaises(ValueError): p.process(self.image,1,0)
        finally: p.close()

    def test_color_roundtrip(self):
        values=np.arange(256,dtype=np.uint8)
        np.testing.assert_array_equal(encoded(linear(values)),values)

    def test_roi_masks_roundtrip(self):
        for mask in [np.zeros((6,9),np.uint8),np.ones((6,9),np.uint8),np.eye(6,9,dtype=np.uint8)]:
            record=mask_record(mask);flat=np.zeros(mask.size,np.uint8)
            for start,length in record['runs']:flat[start:start+length]=1
            np.testing.assert_array_equal(flat.reshape(mask.shape),mask)

    def test_closed_eye_never_reuses_open_iris(self):
        p=Pipeline(engine='geometry')
        try:
            r=p.analyze(self.image,0,0);out=self.image.copy()
            for name,e in r['eyes'].items():
                p.history[name]={'old':'open iris'}
                e['reason']='blink'
                p.render_eye(self.image,out,e,name,1/24)
                self.assertFalse(e['rendered'])
                self.assertNotIn(name,p.history)
            np.testing.assert_array_equal(out,self.image)
        finally:p.close()

    def test_no_face_calibration_times_out(self):
        p=Pipeline(engine='geometry')
        try:
            blank=np.full_like(self.image,120)
            p.process(blank,0,0,command='calibrate')
            _,r=p.process(blank,1,13)
            self.assertFalse(p.calibration.collecting)
            self.assertIn('Insufficient',r['calibration'])
        finally:p.close()

    def test_neural_models_verified_and_execute(self):
        p=Pipeline(engine='neural')
        try:
            _,r=p.process(self.image,0,0)
            self.assertTrue(any('neural' in e for e in r['eyes'].values()))
            self.assertIn('CPUExecutionProvider',r['providers'])
        finally: p.close()

    def test_target_follows_head_translation_without_pixel_lag(self):
        p=Pipeline(engine='geometry')
        try:
            basis=np.eye(2);center=np.array([100.,100.]);goal=np.array([102.,98.])
            p.stabilize_target('left',goal,center,basis,50,1/24,True)
            moved=p.stabilize_target('left',goal+[120,80],center+[120,80],basis,50,1/24,True)
            np.testing.assert_allclose(moved,goal+[120,80],atol=1e-6)
            p.stabilize_target('left',goal,center,basis,50,1/24,False)
            self.assertNotIn('left',p.targets)
        finally:p.close()

    def test_mouth_motion_does_not_rotate_full_face_pose(self):
        p=Pipeline(engine='geometry')
        try:
            # The full-face rotation is fixed while the lower face deforms.
            points=np.zeros((478,2),np.float32)
            model=np.array([[0,0,0],[0,63,12],[-43,-32,26],[43,-32,26],[-28,28,24],[28,28,24]],float)
            k=np.array([[1472,0,640],[0,1472,360],[0,0,1]],float)
            projected=(model+[0,0,600])@k.T
            points[[1,152,33,263,61,291]]=projected[:,:2]/projected[:,2:]
            a=p.pose(points,1280,720,1/24,np.eye(4))
            points[[61,291]] += [15,25]
            b=p.pose(points,1280,720,1/24,np.eye(4))
            np.testing.assert_allclose(a['angles'],b['angles'],atol=1e-6)
            self.assertGreater(b['reprojectionErrorPixels'],a['reprojectionErrorPixels'])
        finally:p.close()


if __name__=='__main__': unittest.main()
