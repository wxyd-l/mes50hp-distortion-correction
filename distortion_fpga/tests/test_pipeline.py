"""Composition checks that unit tests of Gamma or geometry alone cannot cover."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

import cv2
import numpy as np

from software.cli import main
from software.enhancement import GammaFrameState, apply_gamma
from software.pipeline import process_frame
from software.reference import bilinear_fixed, fixed_map, synthetic_config


class PipelineTests(unittest.TestCase):
    def test_gamma_is_before_interpolation(self):
        config = synthetic_config(2, 2)
        config["camera_matrix"] = [[2, 0, 0], [0, 2, 0], [0, 0, 1]]
        config["distortion"] = [0, 0, 0, 0]
        config["output_to_ideal"] = [[1, 0, .5], [0, 1, 0]]
        raw = np.repeat(np.uint8([[0, 255], [100, 200]])[..., None], 3, axis=2)
        corrected, _, _ = process_frame(config, raw, GammaFrameState(), mode="fixed", bank=0)
        post_gamma = apply_gamma(bilinear_fixed(raw, *fixed_map(config)), 0)
        self.assertEqual(int(corrected[0, 0, 0]), 128)
        self.assertGreater(int(post_gamma[0, 0, 0]), 175)

    def test_geometry_black_border_does_not_change_exposure_statistics(self):
        config = synthetic_config(32, 24)
        config["output_to_ideal"] = [[1, 0, 16], [0, 1, 0]]
        raw = np.full((24, 32, 3), 64, np.uint8)
        state = GammaFrameState()
        corrected, _, metadata = process_frame(config, raw, state)
        self.assertEqual(metadata["raw_sum"], 64 * 32 * 24)
        self.assertEqual(metadata["raw_count"], 32 * 24)
        self.assertTrue(np.any(np.all(corrected == 0, axis=2)))

    def test_pose_export_and_sequence_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            dst = Path(directory)
            config = synthetic_config(32, 24)
            (dst / "camera.json").write_text(json.dumps(config), encoding="utf-8")
            for index in range(3):
                cv2.imwrite(str(dst / f"raw_{index:02d}.png"), np.full((24, 32, 3), 24, np.uint8))
            with contextlib.redirect_stdout(io.StringIO()):
                main(["pose", "--config", str(dst / "camera.json"), "--yaw", "5", "--pitch", "-3",
                      "--output", str(dst / "pose.json")])
                main(["export", "--config", str(dst / "pose.json"), "--output", str(dst / "params")])
                main(["process", "--config", str(dst / "pose.json"), "--images", str(dst / "raw_*.png"),
                      "--output", str(dst / "result")])
            self.assertEqual(len((dst / "params/parameters.mem").read_text().splitlines()), 17)
            report = json.loads((dst / "result/pipeline_report.json").read_text())
            self.assertEqual([item["used_bank"] for item in report["frames"]], [3, 2, 1])
            for entry in report["frames"]:
                self.assertEqual(len(entry["sha256"]), 64)
                self.assertEqual(cv2.imread(str(dst / "result" / entry["output"])).shape, (24, 32, 3))


if __name__ == "__main__":
    unittest.main()
