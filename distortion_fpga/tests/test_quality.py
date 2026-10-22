"""Independent analytic checks of quality measurements on SYNTHETIC images."""
import contextlib
import io
import json
import math
from pathlib import Path
import tempfile
import unittest

import cv2
import numpy as np

from software.quality import fit_line_tls, main, read_linear_image, slanted_edge_sfr, straightness_report


def synthetic_gaussian_edge(sigma, angle=5., phase=.17, width=160, height=192):
    """Convolve a step with a Gaussian on a 1/256-pixel grid, then point-sample.

    A cumulative kernel is the discrete convolution of a unit step and that
    kernel. This generator does not use the estimator's bins, derivative or FFT.
    No pixel-area integration is included in this particular reference signal.
    """
    oversample = 256
    n = math.ceil(8 * sigma * oversample)
    coordinate = np.arange(-n, n + 1, dtype=np.float64) / oversample
    kernel = np.exp(-coordinate**2 / (2 * sigma**2))
    profile = np.cumsum(kernel) / np.sum(kernel)
    yy, xx = np.indices((height, width))
    slope = np.tan(np.deg2rad(angle))
    distance = (xx - (width - 1) / 2 - slope * (yy - (height - 1) / 2) - phase) / np.sqrt(1 + slope**2)
    return .1 + .8 * np.interp(distance, coordinate + .5 / oversample, profile, left=0, right=1)


class StraightnessTests(unittest.TestCase):
    def test_tls_reports_known_perpendicular_distances_after_rotation(self):
        x = np.array([-2., -1, 0, 1, 2]) * 10
        y = np.array([.2, -.4, .4, -.4, .2])
        points = np.column_stack([x, y])
        for angle in (0., .43, np.pi / 2):
            rotation = np.array([[np.cos(angle), -np.sin(angle)], [np.sin(angle), np.cos(angle)]])
            moved = points @ rotation.T + [123, 247]
            result = fit_line_tls(moved)
            self.assertAlmostEqual(result["rms_perpendicular_px"], np.sqrt(np.mean(y**2)), places=12)
            self.assertAlmostEqual(result["max_abs_perpendicular_px"], .4, places=12)
            self.assertAlmostEqual(result["span_px"], 40, places=12)

    def test_whole_curve_cannot_be_silently_split_into_short_lines(self):
        x = np.linspace(-50, 50, 101)
        y = .004 * x**2
        report = straightness_report({"provenance": "synthetic", "lines": [{"id": "bowed", "points": np.column_stack([x, y]).tolist()}]})
        result = report["lines"][0]
        self.assertEqual(result["point_count"], 101)
        self.assertAlmostEqual(result["rms_perpendicular_px"], np.std(y), places=12)
        self.assertAlmostEqual(result["max_abs_perpendicular_px"], max(abs(y - y.mean())), places=12)


class SfrTests(unittest.TestCase):
    def test_gaussian_mtf50_against_analytic_frequency_across_blur_angle_phase(self):
        # Analytic Fourier transform of a unit-area Gaussian LSF.
        angles = (2.5, 3., np.degrees(np.arctan(1 / 16)), np.degrees(np.arctan(1 / 12)),
                  5., -7., np.degrees(np.arctan(1 / 8)), 9.5)
        for sigma in (.48, .5, .75, 1.5, 3., 5.):
            expected = np.sqrt(np.log(2)) / (np.sqrt(2) * np.pi * sigma)
            for angle in angles:
                for phase in (0., .13, .37, .73):
                    with self.subTest(sigma=sigma, angle=angle, phase=phase):
                        report = slanted_edge_sfr(synthetic_gaussian_edge(sigma, angle, phase))
                        self.assertEqual(report["status"], "ok")
                        measured = report["mtf50_cycles_per_pixel"]
                        self.assertLess(abs(measured / expected - 1), .02)
                        self.assertAlmostEqual(report["edge_angle_from_axis_degrees"], abs(angle), delta=.02)
                        frequency = np.asarray(report["curves"]["frequency_cycles_per_pixel"])
                        sfr = np.asarray(report["curves"]["sfr"])
                        inside = frequency <= min(.4, 2 * expected)
                        analytic = np.exp(-2 * np.pi**2 * sigma**2 * frequency[inside]**2)
                        self.assertLess(np.max(abs(sfr[inside] - analytic)), .02)

    def test_pixel_area_blur_is_retained_in_the_measured_response(self):
        sigma, angle, phase = .7, 5., .17
        slope = np.tan(np.deg2rad(angle))
        offsets = (np.arange(8) + .5) / 8 - .5
        image = sum(synthetic_gaussian_edge(sigma, angle, phase - dx + slope * dy)
                    for dx in offsets for dy in offsets) / 64
        normal = np.array([1., slope]) / np.sqrt(1 + slope**2)
        low, high = 0., .5
        for _ in range(60):
            mid = (low + high) / 2
            mtf = np.exp(-2 * np.pi**2 * sigma**2 * mid**2) * np.prod(np.sinc(mid * normal))
            if mtf > .5:
                low = mid
            else:
                high = mid
        expected = (low + high) / 2
        measured = slanted_edge_sfr(image)["mtf50_cycles_per_pixel"]
        self.assertLess(abs(measured / expected - 1), .02)

    def test_eight_bit_quantization_and_one_code_value_noise(self):
        rng = np.random.default_rng(20261022)
        for sigma in (.5, 1.5, 3.):
            image = synthetic_gaussian_edge(sigma)
            noisy = np.rint((image + rng.normal(0, 1 / 255, image.shape)) * 255) / 255
            measured = slanted_edge_sfr(noisy)["mtf50_cycles_per_pixel"]
            expected = np.sqrt(np.log(2)) / (np.sqrt(2) * np.pi * sigma)
            self.assertLess(abs(measured / expected - 1), .03)

    def test_horizontal_polarity_and_roi_coordinates_preserve_measurement(self):
        image = synthetic_gaussian_edge(1.2)
        original = slanted_edge_sfr(image)
        padded = np.pad(1 - image.T, ((7, 9), (11, 13)), constant_values=.5)
        changed = slanted_edge_sfr(padded, (11, 7, image.shape[0], image.shape[1]), "horizontal")
        self.assertAlmostEqual(changed["mtf50_cycles_per_pixel"], original["mtf50_cycles_per_pixel"], places=12)

    def test_derivative_correction_has_independently_known_transfer_function(self):
        report = slanted_edge_sfr(synthetic_gaussian_edge(.5))
        curve = report["curves"]
        self.assertAlmostEqual(curve["derivative_correction"][-1], (np.pi / 4) / np.sin(np.pi / 4), places=12)
        freq = np.asarray(curve["frequency_cycles_per_pixel"])
        expected = np.exp(-2 * np.pi**2 * .5**2 * freq**2)
        at = np.argmin(abs(freq - .35))
        self.assertLess(abs(curve["sfr"][at] - expected[at]), abs(curve["sfr_without_corrections"][at] - expected[at]))

    def test_unresolved_sharp_edge_has_no_invented_mtf50(self):
        report = slanted_edge_sfr(synthetic_gaussian_edge(.3))
        self.assertEqual(report["status"], "not_measurable")
        self.assertIsNone(report["mtf50_cycles_per_pixel"])
        self.assertIn("curves", report)

    def test_broad_edge_needs_wider_roi_before_windowing(self):
        with self.assertRaisesRegex(ValueError, "window taper"):
            slanted_edge_sfr(synthetic_gaussian_edge(12., width=96))
        result = slanted_edge_sfr(synthetic_gaussian_edge(12., width=256))
        expected = np.sqrt(np.log(2)) / (np.sqrt(2) * np.pi * 12)
        self.assertLess(abs(result["mtf50_cycles_per_pixel"] / expected - 1), .02)

    def test_curved_edge_is_rejected_instead_of_warping_each_row_straight(self):
        image = synthetic_gaussian_edge(1.)
        yy, xx = np.indices(image.shape)
        curved = cv2.remap(image, (xx + .0007 * (yy - 95.5)**2).astype(np.float32), yy.astype(np.float32), cv2.INTER_LINEAR)
        with self.assertRaisesRegex(ValueError, "line-fit RMS"):
            slanted_edge_sfr(curved)

    def test_explicit_transfer_curve_and_cli_json(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            image = synthetic_gaussian_edge(1.5)
            srgb = np.where(image <= .0031308, image * 12.92, 1.055 * image**(1 / 2.4) - .055)
            source = temp / "SYNTHETIC_edge.png"
            cv2.imwrite(str(source), np.rint(srgb * 65535).astype(np.uint16))
            decoded = read_linear_image(source, "srgb")
            np.testing.assert_allclose(decoded, image, atol=2e-5)
            output = temp / "quality.json"
            with contextlib.redirect_stdout(io.StringIO()):
                code = main(["sfr", "--image", str(source), "--roi", "0", "0", "160", "192",
                             "--orientation", "vertical", "--encoding", "srgb", "--output", str(output)])
            self.assertEqual(code, 0)
            result = json.loads(output.read_text(encoding="utf-8"))
            self.assertIn("esf_linear", result["curves"])
            expected = np.sqrt(np.log(2)) / (np.sqrt(2) * np.pi * 1.5)
            self.assertAlmostEqual(result["mtf50_cycles_per_pixel"], expected, delta=.002)


if __name__ == "__main__":
    unittest.main()
