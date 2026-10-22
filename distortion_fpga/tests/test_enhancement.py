"""Independent invariants and frame-causality checks for Gamma preprocessing."""
import unittest
import numpy as np
from software.enhancement import GAMMAS, GammaFrameState, apply_gamma, gamma_lut, luma_u8, select_target


class EnhancementTests(unittest.TestCase):
    def test_all_luts_and_known_values(self):
        for i, gamma in enumerate(GAMMAS):
            lut = gamma_lut(i)
            self.assertEqual(int(lut[0]), 0)
            self.assertEqual(int(lut[255]), 255)
            self.assertTrue(np.all(np.diff(lut.astype(int)) >= 0))
            # Independent scalar power calculation, including both rounding endpoints.
            self.assertEqual(lut.tolist(), [int(255*(x/255)**gamma+0.5) for x in range(256)])
        np.testing.assert_array_equal(gamma_lut(3), np.arange(256))
        self.assertEqual(int(gamma_lut(0)[64]), 128)
        self.assertEqual(int(gamma_lut(6)[128]), 64)

    def test_raw_luma_weights_and_neutrality(self):
        rgb=np.array([[[255,0,0],[0,255,0],[0,0,255],[32,32,32]]],np.uint8)
        np.testing.assert_array_equal(luma_u8(rgb), [[77,149,29,32]])
        gray=np.repeat(np.arange(256,dtype=np.uint8)[None,:,None],3,axis=-1)
        for bank in range(7):
            result=apply_gamma(gray,bank)
            np.testing.assert_array_equal(result[...,0], result[...,1])
            np.testing.assert_array_equal(result[...,0], result[...,2])

    def test_constant_scene_converges_without_integral_drift(self):
        state=GammaFrameState()
        dark=np.full((2,3,3),32,np.uint8)
        reports=[state.process(dark)[1] for _ in range(10)]
        self.assertEqual([r['used_bank'] for r in reports], [3,2,1,1,1,1,1,1,1,1])
        bright=np.full((2,3,3),224,np.uint8)
        reports=[state.process(bright)[1] for _ in range(10)]
        self.assertEqual([r['used_bank'] for r in reports], [1,2,3,4,5,6,6,6,6,6])
        self.assertEqual(reports[-1]['raw_sum'],224*6)

    def test_hysteresis_uses_target_not_delayed_applied_bank(self):
        self.assertEqual(select_target(99,1,2),2)
        self.assertEqual(select_target(100,1,2),3)
        self.assertEqual(select_target(92,1,3),3)
        self.assertEqual(select_target(91,1,3),2)
        # Exact rational mean matters: 99.5 stays while 100 crosses.
        self.assertEqual(select_target(199,2,2),2)
        self.assertEqual(select_target(200,2,2),3)

    def test_switching_modes_restarts_adaptation(self):
        state=GammaFrameState()
        dark=np.full((1,1,3),32,np.uint8)
        for _ in range(4): state.process(dark)
        image,r=state.process(dark,'fixed',0)
        self.assertEqual(r['used_bank'],0)
        self.assertGreater(int(image[0,0,0]),32)
        self.assertEqual(state.process(dark)[1]['used_bank'],3)
        self.assertEqual(state.process(dark)[1]['used_bank'],2)
        np.testing.assert_array_equal(state.process(dark,'bypass')[0],dark)

    def test_clipped_input_information_stays_clipped(self):
        image=np.array([[[0,0,0],[255,255,255]]],np.uint8)
        for bank in range(7): np.testing.assert_array_equal(apply_gamma(image,bank),image)


if __name__ == '__main__':
    unittest.main()
