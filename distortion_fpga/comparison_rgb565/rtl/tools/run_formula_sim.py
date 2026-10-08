"""Validate a formula package, simulate RGB565 frame through the shared cache."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import sys
import time

import numpy as np

from run_sim import run
from compare_mappers import ROOT
from polynomial import validate_parameters, packed_parameters
from memory_profile import source_read_trace,cache_stats


def read_words(path,count,digits):
    def words():
        for line in Path(path).read_text(encoding='ascii').splitlines():
            if len(line)!=digits or any(c not in '0123456789abcdefABCDEF' for c in line):
                raise ValueError('invalid formula memory word')
            yield int(line,16)
    values = np.fromiter(words(),dtype=np.int64)
    if values.size != count:raise ValueError('formula memory dimensions mismatch')
    return values


def validate_package(package):
    package = Path(package)
    report = json.loads((package/'package.json').read_text(encoding='utf-8'))
    if report.get('schema')!='brown_formula_test_v1':raise ValueError('unsupported formula package')
    for name,maximum in (('input_size',32768),('output_size',65535)):
        size = report[name]
        if len(size)!=2 or any(type(v) is not int or not 2<=v<=maximum for v in size) or size[0]*size[1]>(1<<24):
            raise ValueError('formula dimensions exceed source Q16/output/address limits')
    validate_parameters(report['parameters'])
    n = report['output_size'][0]*report['output_size'][1]
    if (report.get('coordinate_fraction_bits')!=16 or report.get('parameter_field_bits')!=32 or
            report.get('parameter_bus_bits')!=448 or type(report.get('invalid_pixels')) is not int or
            type(report.get('overflow_pixels')) is not int or not 0<=report['invalid_pixels']<=n or
            report['overflow_pixels'] not in (0,n) or report['overflow_pixels']>report['invalid_pixels']):
        raise ValueError('invalid formula contract/accounting')
    required = {'source_rgb565.memh','expected_rgb565.memh','expected_valid.memh',
                'expected_x.memh','expected_y.memh','parameters.memh'}
    if set(report['sha256'])!=required:raise ValueError('incomplete formula manifest')
    for name,digest in report['sha256'].items():
        if hashlib.sha256((package/name).read_bytes()).hexdigest()!=digest:raise ValueError(f'formula checksum failed: {name}')
    if (package/'parameters.memh').read_text(encoding='ascii')!=f'{packed_parameters(report["parameters"]):0112x}\n':
        raise ValueError('formula parameter bus differs from metadata')
    width,height = report['output_size']
    coords=[]
    for name in ('expected_x.memh','expected_y.memh'):
        raw = read_words(package/name,n,8)
        coords.append(np.where(raw>=(1<<31),raw-(1<<32),raw).reshape(height,width))
    mask = read_words(package/'expected_valid.memh',n,1)
    if np.any(mask>1) or np.count_nonzero(mask==0)!=report['invalid_pixels']:
        raise ValueError('formula validity accounting mismatch')
    if report['overflow_pixels']:
        if any(np.any(axis) for axis in coords):raise ValueError('overflow oracle coordinates must retire as zero')
        trace=np.empty(0,np.int64)
    else:
        trace,valid=source_read_trace(*coords,report['input_size'],16)
        if not np.array_equal(valid.flat,mask.astype(bool)):raise ValueError('formula coordinate/mask disagreement')
    oracle=cache_stats(trace,32768,line_bytes=32,ways=2)
    return report,oracle


def simulate(package):
    package = Path(package).resolve()
    report,oracle = validate_package(package)
    root = ROOT/'rtl'
    identity = hashlib.sha256((package/'package.json').read_bytes()).hexdigest()[:12]
    directory = root/'out'/f'formula-{identity}'
    directory.mkdir(parents=True,exist_ok=True)
    for name in report['sha256']:shutil.copyfile(package/name,directory/name)
    sw,sh = report['input_size'];width,height=report['output_size']
    defines={'SW':sw,'SH':sh,'W':width,'H':height,'OVERFLOW':report['overflow_pixels'],
             'HITS':oracle['hits'],'MISSES':oracle['misses']}
    (directory/'formula_parameters.vh').write_text(''.join(f'`define FORMULA_{name} {value}\n' for name,value in defines.items()),encoding='ascii')
    sources = [root/'formula'/name for name in ('brown_mapper_pipeline.sv','brown_frame_writer.sv','tb_formula_frame.sv','tb_formula_mapper.sv')]
    sources += [root/'src'/name for name in ('bilinear_signed.v','bilinear_rgb565.v','rgb565_read_cache.v')]
    sources += [root/'sim/tb_line_memory.sv',root/'tools/run_formula_sim.py',root/'tools/compare_mappers.py']
    checksums={p.relative_to(root).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    algorithm_hashes={name:hashlib.sha256((ROOT/'algorithm'/name).read_bytes()).hexdigest()
                      for name in ('polynomial.py','geometry.py','undistort.py','memory_profile.py')}
    executables={name:shutil.which(name) for name in ('vlib','vmap','vlog','vsim')}
    if not all(executables.values()):raise RuntimeError('ModelSim commands must be on PATH')
    log=[];started=time.monotonic()
    try:
        if not (directory/'modelsim.ini').exists():run([executables['vmap'],'-c'],directory,log)
        if not (directory/'work').exists():run([executables['vlib'],'work'],directory,log)
        run([executables['vmap'],'work','work'],directory,log)
        run([executables['vlog'],'-sv','-work','work',f'+incdir+{directory.as_posix()}',
             *[str(p) for p in sources if p.suffix in ('.sv','.v')]],directory,log)
        mapper_markers=[]
        if width*height<10000:
            mapper_output=run([executables['vsim'],'-c','-lib','work','tb_formula_mapper','-do',
                               'onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0'],directory,log)
            mapper_markers=[line for line in mapper_output.splitlines() if 'FORMULA_MAPPER_PASSED' in line]
            if len(mapper_markers)!=2:raise RuntimeError('missing continuous/CE formula mapper success\n'+mapper_output)
        output=run([executables['vsim'],'-c','-lib','work','tb_formula_frame','-do',
                    'onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0'],directory,log)
        markers=[line for line in output.splitlines() if 'FORMULA_FRAME_PASSED' in line]
        if len(markers)!=1:raise RuntimeError('missing formula frame success\n'+output)
        if any(hashlib.sha256(p.read_bytes()).hexdigest()!=checksums[p.relative_to(root).as_posix()] for p in sources):
            raise RuntimeError('formula sources changed during verification')
        if any(hashlib.sha256((ROOT/'algorithm'/name).read_bytes()).hexdigest()!=digest for name,digest in algorithm_hashes.items()):
            raise RuntimeError('formula reference changed during verification')
        result={'package':str(package),'passed':True,'result':markers[0],'mapper_tests':mapper_markers,
                'cache_oracle':oracle,'source_sha256':checksums,'algorithm_source_sha256':algorithm_hashes,
                'verified_at_utc':datetime.now(timezone.utc).isoformat(),'elapsed_seconds':time.monotonic()-started,
                'scope':'Local formula branch, RGB565, shared artificial backend. Not the original RGB888 team top, '
                        'PDS synthesis, physical DDR, lens calibration or board speed.'}
        (directory/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
        print(markers[0],flush=True);print(f'Report: {directory / "result.json"}')
        return result
    finally:
        (directory/'simulation.log').write_text('\n'.join(log),encoding='utf-8')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--package',type=Path,required=True)
    args=p.parse_args();simulate(args.package)
