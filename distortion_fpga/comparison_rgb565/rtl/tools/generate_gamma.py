"""Static RGB565 Gamma tables: gamma > 1 brightens, gamma = 1 is identity."""
import argparse
import json
import math
from pathlib import Path


def table(bits, gamma):
    if not math.isfinite(gamma) or not .1 <= gamma <= 10:
        raise ValueError('gamma must be finite and in [0.1,10]')
    if bits not in (5,6):
        raise ValueError('only RGB565 channel widths 5 and 6 are supported')
    maximum = (1 << bits)-1
    return [int(math.floor(maximum*(value/maximum)**(1/gamma)+.5)) for value in range(maximum+1)]


def generate(out, gamma=1.8):
    r, g = table(5,gamma), table(6,gamma)
    out=Path(out);out.mkdir(parents=True,exist_ok=True)
    (out/'gamma5.memh').write_text(''.join(f'{value:02x}\n' for value in r),encoding='ascii')
    (out/'gamma6.memh').write_text(''.join(f'{value:02x}\n' for value in g),encoding='ascii')
    report={'gamma':gamma,'formula':'max*(in/max)**(1/gamma), nearest/ties up',
            'channel_maximums':[31,63,31], 'black_preserved':True,
            'warning':'Static RGB565 per-channel Gamma; not automatic exposure or histogram equalization.'}
    (out/'gamma.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    return r,g


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--gamma',type=float,default=1.8)
    args=parser.parse_args();generate(args.out,args.gamma)
