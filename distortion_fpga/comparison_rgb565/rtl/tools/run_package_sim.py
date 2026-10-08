"""Simulate one complete test package, checking every RTL-written pixel."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import time
from datetime import datetime, timezone

from prepare_package import read_grid
from run_sim import run
from reference import dense_grid


def simulate(package, fast_map=False, cache=False, cache_line_log2=4, cache_set_log2=9):
    package=package.resolve()
    metadata,grid=read_grid(package)
    report=json.loads((package/'package.json').read_text(encoding='utf-8'))
    params=report['parameters']
    required={'SRC_WIDTH':metadata['input_size'][0],'SRC_HEIGHT':metadata['input_size'][1],
              'OUT_WIDTH':metadata['output_size'][0],'OUT_HEIGHT':metadata['output_size'][1],
              'GRID_LOG2':metadata['grid_step'].bit_length()-1,'COORD_FRAC':metadata['frac_bits'],'ADDR_BITS':24}
    if (report.get('schema')!='rtl_test_package_v1' or set(params)!=set(required)|{'WEIGHT_FRAC'}
            or any(type(v) is not int for v in params.values())
            or any(params.get(k)!=v for k,v in required.items()) or params.get('WEIGHT_FRAC') not in (8,16)):
        raise ValueError('package parameters differ from grid metadata')
    if set(report['sha256'])!={'grid.memh','grid.json','source_rgb565.memh','expected_rgb565.memh','expected_valid.memh','rtl_parameters.vh'}:
        raise ValueError('package checksum manifest is incomplete')
    for name,digest in report['sha256'].items():
        if Path(name).name!=name or hashlib.sha256((package/name).read_bytes()).hexdigest()!=digest:
            raise ValueError(f'package checksum failed for {name}')
    root=Path(__file__).resolve().parents[1]
    cache_oracle=None
    if cache:
        if (type(cache_line_log2) is not int or type(cache_set_log2) is not int
                or not 1<=cache_line_log2<=8 or not 1<=cache_set_log2<=14
                or cache_line_log2+cache_set_log2>=params['ADDR_BITS']):
            raise ValueError('invalid cache widths')
        from memory_profile import source_read_trace,cache_stats
        trace,_=source_read_trace(*dense_grid(grid,metadata['output_size'],params['WEIGHT_FRAC']),
                                  metadata['input_size'],metadata['frac_bits'])
        cache_oracle=cache_stats(trace,2*(1<<cache_set_log2)*(1<<cache_line_log2)*2,
                                line_bytes=(1<<cache_line_log2)*2,ways=2)
    identity=hashlib.sha256((package/'package.json').read_bytes()).hexdigest()[:12]
    directory=root/'out'/(f'package-{identity}'+('-fast' if fast_map else '')+
                           (f'-cachel{cache_line_log2}s{cache_set_log2}' if cache else ''))
    directory.mkdir(parents=True,exist_ok=True)
    for name in ('grid.memh','source_rgb565.memh','expected_rgb565.memh','expected_valid.memh'):
        shutil.copyfile(package/name,directory/name)
    # Regenerate the include from validated integers; do not execute a supplied header.
    (directory/'rtl_parameters.vh').write_text(''.join(f'`define REMAP_{k} {v}\n' for k,v in params.items())+
        f'`define REMAP_USE_FAST_MAP {int(fast_map)}\n'+(''.join(f'`define REMAP_CACHE_{k} {v}\n' for k,v in {
            'LINE_LOG2':cache_line_log2,'SET_LOG2':cache_set_log2,
            'EXPECTED_HITS':cache_oracle['hits'],'EXPECTED_MISSES':cache_oracle['misses']}.items()) if cache else ''),encoding='ascii')
    executables={name:shutil.which(name) for name in ('vlib','vmap','vlog','vsim')}
    if not all(executables.values()):raise RuntimeError('ModelSim commands must be on PATH')
    log=[];started=time.monotonic()
    try:
        if not (directory/'modelsim.ini').exists():run([executables['vmap'],'-c'],directory,log)
        if not (directory/'work').exists():run([executables['vlib'],'work'],directory,log)
        run([executables['vmap'],'work','work'],directory,log)
        sources=sorted(p for p in (root/'src').glob('*.v') if cache or p.name!='rgb565_read_cache.v')+[
            root/'sim'/('tb_line_memory.sv' if cache else 'tb_memory.sv'),
            root/'sim'/('tb_package_cache.sv' if cache else 'tb_package.sv')]
        checksums={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
        run([executables['vlog'],'-sv','-work','work',f'+incdir+{directory.as_posix()}',*[str(p) for p in sources]],directory,log)
        output=run([executables['vsim'],'-c','-lib','work','tb_package_cache' if cache else 'tb_package','-do',
                    'onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0'],directory,log)
        lines=[line for line in output.splitlines() if 'PACKAGE_RTL_PASSED' in line]
        if len(lines)!=1:raise RuntimeError('Missing simulation success marker\n'+output)
        if any(hashlib.sha256(p.read_bytes()).hexdigest()!=checksums[str(p.relative_to(root))] for p in sources):
            raise RuntimeError('Source files changed during simulation; rerun to verify the new source.')
        result={'package':str(package),'passed':True,'result':lines[0],'fast_mapper':fast_map,
                'cache_enabled':cache,'cache_oracle':cache_oracle,
                'verified_at_utc':datetime.now(timezone.utc).isoformat(),'source_sha256':checksums,
                'logical_lut_storage_bytes':int(grid[2].size*16*(4 if fast_map else 1)),
                'elapsed_seconds':round(time.monotonic()-started,3),'synthetic_or_real_provenance':
                'Input provenance is not verified; simulation is not board validation.'}
        (directory/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
        print(lines[0],flush=True);print(f'Report: {directory / "result.json"}')
        return result
    finally:
        (directory/'simulation.log').write_text('\n'.join(log),encoding='utf-8')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package',type=Path,required=True)
    parser.add_argument('--fast-map',action='store_true')
    parser.add_argument('--cache',action='store_true',help='simulate through the generic two-way read cache and line backend')
    parser.add_argument('--cache-line-log2',type=int,default=4)
    parser.add_argument('--cache-set-log2',type=int,default=9)
    args=parser.parse_args();simulate(args.package,args.fast_map,args.cache,args.cache_line_log2,args.cache_set_log2)
