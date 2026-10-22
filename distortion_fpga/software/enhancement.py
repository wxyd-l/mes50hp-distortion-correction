"""Frame-causal, integer RGB Gamma preprocessing reference."""
from __future__ import annotations

from dataclasses import dataclass
import numpy as np

GAMMAS = (0.5, 0.65, 0.8, 1.0, 1.25, 1.5, 2.0)
THRESHOLDS = (32, 64, 96, 160, 192, 224)
HYSTERESIS = 4


def gamma_lut(bank):
    if not isinstance(bank, (int, np.integer)) or not 0 <= bank < len(GAMMAS):
        raise ValueError("Gamma bank must be an integer from 0 to 6")
    x = np.arange(256, dtype=np.float64) / 255.0
    return np.floor(255.0 * x ** GAMMAS[bank] + 0.5).astype(np.uint8)


def apply_gamma(image, bank):
    image = np.asarray(image)
    if image.dtype != np.uint8:
        raise ValueError("Gamma input must be uint8")
    return gamma_lut(bank)[image]


def luma_u8(image):
    image = np.asarray(image)
    if image.dtype != np.uint8 or image.ndim != 3 or image.shape[-1] != 3 or image.size == 0:
        raise ValueError("Input must be a nonempty HxWx3 uint8 RGB image")
    rgb = image.astype(np.uint32)
    return ((77*rgb[..., 0] + 150*rgb[..., 1] + 29*rgb[..., 2] + 128) >> 8).astype(np.uint8)


def select_target(sum_y, count, previous_target=3):
    """Compare sum against count*threshold, without quantizing the mean."""
    if count <= 0 or not 0 <= sum_y <= 255*count or not 0 <= previous_target <= 6:
        raise ValueError("Invalid frame statistics or target")
    lower = previous_target == 0 or sum_y >= count*(THRESHOLDS[previous_target-1]-HYSTERESIS)
    upper = previous_target == 6 or sum_y < count*(THRESHOLDS[previous_target]+HYSTERESIS)
    if lower and upper:
        return previous_target
    return sum(sum_y >= count*t for t in THRESHOLDS)


@dataclass
class GammaFrameState:
    """New adaptive sessions start at identity; continuous sessions use prior frames."""
    mode: str = "bypass"
    next_bank: int = 3
    target_bank: int = 3

    def process(self, image, mode="adaptive", bank=3):
        if mode not in ("bypass", "fixed", "adaptive"):
            raise ValueError("mode must be bypass, fixed, or adaptive")
        gamma_lut(bank)
        luma = luma_u8(image)
        raw_sum, raw_count = int(luma.sum(dtype=np.uint64)), int(luma.size)
        if raw_count > 0xffffffff:
            raise ValueError("Frame exceeds the 32-bit pixel counter")
        if mode == "adaptive":
            if self.mode != "adaptive":
                self.next_bank = self.target_bank = 3
            used_bank = self.next_bank
            self.target_bank = select_target(raw_sum, raw_count, self.target_bank)
            self.next_bank = used_bank + int(self.target_bank > used_bank) - int(self.target_bank < used_bank)
        else:
            used_bank = bank if mode == "fixed" else 3
            self.next_bank = self.target_bank = 3
        self.mode = mode
        report = {"mode": mode, "used_bank": used_bank, "gamma": GAMMAS[used_bank],
                  "raw_sum": raw_sum, "raw_count": raw_count, "raw_mean": raw_sum/raw_count,
                  "target_bank": self.target_bank, "next_bank": self.next_bank,
                  "saturated_input_fraction": float(np.mean(np.any(image == 255, axis=-1)))}
        return apply_gamma(image, used_bank), report


FrameGammaState = GammaFrameState
