"""Run isolated cache regressions without modifying the baseline renderer."""
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import shutil
import time

from generate_cache_vectors import generate
from run_sim import run


def main():
    root=Path(__file__).resolve().parents[1]
    executables={name:shutil.which(name) for name in ('vlib','vmap','vlog','vsim')}
    if not all(executables.values()):raise RuntimeError('ModelSim commands must be on PATH')
    reports=[]
    for line_log2,set_log2 in ((2,2),(4,3)):
        directory=root/'out'/f'cache-l{line_log2}-s{set_log2}'
        manifest=generate(directory,line_log2,set_log2);logs=[];started=time.monotonic()
        sources=[root/'src/rgb565_read_cache.v',root/'sim/tb_line_memory.sv',root/'sim/tb_cache.sv']
        hashes={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
        try:
            if not (directory/'modelsim.ini').exists():run([executables['vmap'],'-c'],directory,logs)
            if not (directory/'work').exists():run([executables['vlib'],'work'],directory,logs)
            run([executables['vmap'],'work','work'],directory,logs)
            run([executables['vlog'],'-sv','-work','work',f'+incdir+{directory.as_posix()}',*[str(p) for p in sources]],directory,logs)
            output=run([executables['vsim'],'-c','-lib','work','tb_cache','-do',
                        'onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0'],directory,logs)
            if 'CACHE_RTL_PASSED' not in output or 'CACHE_TRACE_PASSED' not in output:
                raise RuntimeError('Cache success markers missing\n'+output)
            if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(root))] for p in sources):
                raise RuntimeError('Cache sources changed during simulation')
            manifest.update(passed=True,verified_at_utc=datetime.now(timezone.utc).isoformat(),
                source_sha256=hashes,elapsed_seconds=round(time.monotonic()-started,3),
                results=[line for line in output.splitlines() if '_PASSED' in line])
            reports.append(manifest);print('\n'.join(manifest['results']),flush=True)
        finally:(directory/'simulation.log').write_text('\n'.join(logs),encoding='utf-8')
    destination=root/'out/cache_regression.json';destination.write_text(json.dumps(reports,indent=2),encoding='utf-8')
    print(f'Report: {destination}')


if __name__=='__main__':main()
