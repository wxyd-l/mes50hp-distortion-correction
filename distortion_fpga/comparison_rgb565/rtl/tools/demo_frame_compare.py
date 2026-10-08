"""Artificial export/decoding faults to exercise the frame comparison workflow."""
import argparse
import json
from pathlib import Path

import numpy as np

from compare_frame import compare_package,read_memh,swap_red_blue


def demo(package,out):
    package,out=Path(package),Path(out)
    if package.resolve()==out.resolve() or package.resolve() in out.resolve().parents:
        raise ValueError('demo must not modify the reference package')
    manifest=json.loads((package/'package.json').read_text(encoding='utf-8'))
    width,height=manifest['parameters']['OUT_WIDTH'],manifest['parameters']['OUT_HEIGHT']
    expected=read_memh(package/'expected_rgb565.memh',width*height).reshape(height,width)
    valid=read_memh(package/'expected_valid.memh',width*height,1).reshape(height,width)
    out.mkdir(parents=True,exist_ok=True)
    cases=[]
    def run(name,path,format,**options):
        report=compare_package(package,path,out/name,format,**options)
        cases.append({'case':name,'exact_match':report['exact_match'],
                      'mismatched_pixels':report['mismatched_pixels'],
                      'diagnostic_hypotheses':report['diagnostic_hypotheses']})
    run('exact_memh',package/'expected_rgb565.memh','memh',pixel_order='rgb565')
    stride=((width*2+63)//64)*64+64  # Deliberately include padding even for 720P.
    raw=out/'synthetic_bgr_big_stride.raw'
    raw.write_bytes(b''.join(row.astype('>u2').tobytes()+b'\xa5'*(stride-width*2) for row in swap_red_blue(expected)))
    run('bgr_big_stride',raw,'raw565',pixel_order='bgr565',byte_order='big',stride_bytes=stride)
    changed=expected.copy();index=int(np.flatnonzero(valid)[0]) if valid.any() else 0
    changed.flat[index]^=np.uint16(1)
    for name,pixels in (('wrong_red_blue',swap_red_blue(expected)),('wrong_word_bytes',expected.byteswap()),
                        ('wrong_horizontal_flip',expected[:,::-1]),('one_pixel_error',changed)):
        path=out/f'synthetic_{name}.memh'
        path.write_text(''.join(f'{int(value):04x}\n' for value in pixels.flat),encoding='ascii')
        run(name,path,'memh',pixel_order='rgb565')
    if not cases[0]['exact_match'] or not cases[1]['exact_match'] or cases[-1]['mismatched_pixels']!=1:
        raise AssertionError('comparison workflow self-check failed')
    result={'synthetic_only':True,'package':str(package.resolve()),'cases':cases,
            'scope':'Files deliberately generated from the reference, NOT captured from FPGA. Exact results test the comparison tool only.'}
    (out/'summary.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--package',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);args=p.parse_args()
    result=demo(args.package,args.out)
    for case in result['cases']:print(f"{case['case']}: exact={case['exact_match']} mismatches={case['mismatched_pixels']}")
    print(f'Output: {args.out.resolve()}')
