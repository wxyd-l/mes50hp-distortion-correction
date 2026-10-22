"""Generate the small Gamma ROM and synthetic streaming golden vectors."""
from pathlib import Path
import colorsys
import json
import sys
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from software.enhancement import GAMMAS, GammaFrameState, apply_gamma, gamma_lut


def generate():
    (ROOT / 'build').mkdir(exist_ok=True)
    lut = np.concatenate([gamma_lut(i) for i in range(len(GAMMAS))])
    (ROOT / 'rtl/gamma_lut.hex').write_text(''.join(f'{int(v):02x}\n' for v in lut), encoding='ascii')
    frames = []
    ramp = np.arange(256, dtype=np.uint8)
    colors = np.stack([ramp, np.roll(ramp, 73), np.roll(ramp, 151)], axis=-1)[None]
    for bank in range(7):
        frames.append((colors, 'fixed', bank))
    frames += [(colors, 'bypass', 0)]
    for y in [32]*10 + [224]*10 + [95, 96, 99, 100, 96, 92, 91]*2 + [0, 255]:
        frames.append((np.full((2, 7, 3), y, np.uint8), 'adaptive', 3))
    # One-pixel frames test coincident SOF/EOF and adaptive re-entry.
    frames += [(np.full((1, 1, 3), y, np.uint8), mode, 0)
               for y, mode in [(44, 'fixed'), (32, 'adaptive'), (32, 'adaptive'), (32, 'adaptive')]]
    state = GammaFrameState()
    rows = []
    for image, mode, bank in frames:
        output, report = state.process(image, mode, bank)
        pixels, expected = image.reshape(-1, 3), output.reshape(-1, 3)
        for i, (rgb, result) in enumerate(zip(pixels, expected)):
            # Intentionally change configuration during a frame: it must be ignored.
            cfg_mode = {'bypass': 0, 'fixed': 1, 'adaptive': 2}[mode] if i == 0 else i % 3
            cfg_bank = bank if i == 0 else i % 7
            pack = lambda p: (int(p[0]) << 16) | (int(p[1]) << 8) | int(p[2])
            rows.append(f'{pack(rgb):06x} {cfg_mode:x} {cfg_bank:x} {int(i == 0):x} '
                        f'{int(i == len(pixels)-1):x} {pack(result):06x} {report["used_bank"]:x} '
                        f'{report["raw_sum"]:010x} {report["raw_count"]:08x}\n')
    (ROOT / 'build/gamma_vectors.txt').write_text(str(len(rows))+'\n'+''.join(rows), encoding='ascii')
    # Explicit synthetic RGB patches, not a measured ColorChecker chart.
    patches = np.array([[180,70,30],[30,180,70],[70,30,180],[200,150,40],
                        [40,200,150],[150,40,200],[255,128,0],[0,255,128],
                        [128,0,255],[32,32,32],[128,128,128],[224,224,224]],np.uint8)
    hsv = lambda pixels: np.array([colorsys.rgb_to_hsv(*(p.astype(float)/255)) for p in pixels])
    original_hsv = hsv(patches)
    chromatic = original_hsv[:,1] > 0
    color_report = {'kind': 'synthetic RGB patch arithmetic; no camera/colorimetric measurement',
                    'input_rgb': patches.tolist(), 'banks': []}
    for bank, gamma in enumerate(GAMMAS):
        result = apply_gamma(patches,bank)
        dh = np.abs(hsv(result)[:,0]-original_hsv[:,0])
        angle = np.minimum(dh,1-dh)*360
        color_report['banks'].append({'bank':bank,'gamma':gamma,'output_rgb':result.tolist(),
            'chromatic_hue_mean_abs_degrees':float(np.mean(angle[chromatic])),
            'chromatic_hue_max_abs_degrees':float(np.max(angle[chromatic])),
            'any_channel_at_255_fraction':float(np.mean(np.any(result==255,axis=-1)))})
    (ROOT/'build/gamma_color_report.json').write_text(json.dumps(color_report,indent=2)+'\n',encoding='utf-8')
    print(f'Gamma: {len(lut)} ROM bytes; {len(frames)} synthetic frames / {len(rows)} pixels')


if __name__ == '__main__':
    generate()
