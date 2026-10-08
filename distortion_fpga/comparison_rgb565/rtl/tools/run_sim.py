"""Generate independent vectors and run isolated ModelSim regressions."""
import argparse
import json
import itertools
import hashlib
from datetime import datetime, timezone
from pathlib import Path
import shutil
import subprocess
import time

from generate_vectors import generate


def run(command, directory, log):
    result = subprocess.run(command, cwd=directory, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, errors='replace', timeout=180)
    log.append(result.stdout)
    if result.returncode:
        raise RuntimeError(f'{command[0]} exited {result.returncode}:\n{result.stdout}')
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--weight-frac', type=int, choices=(8, 16), nargs='+', default=[16, 8])
    parser.add_argument('--engine-map', choices=('serial','fast'), nargs='+', default=['serial','fast'])
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    executables = {name: shutil.which(name) for name in ('vlib', 'vmap', 'vlog', 'vsim')}
    if not all(executables.values()):
        raise RuntimeError('ModelSim commands vlib, vmap, vlog, vsim must be on PATH.')
    reports = []
    for fraction, engine_map in itertools.product(args.weight_frac,args.engine_map):
        directory = root / 'out' / (f'wf{fraction}' + ('-fast' if engine_map=='fast' else ''))
        vectors = directory / 'vectors'
        manifest = generate(vectors, fraction)
        manifest['engine_mapper']=engine_map
        manifest['started_at_utc']=datetime.now(timezone.utc).isoformat()
        log = []
        started = time.monotonic()
        try:
            if not (directory / 'modelsim.ini').exists():
                run([executables['vmap'], '-c'], directory, log)
            if not (directory / 'work').exists():
                run([executables['vlib'], 'work'], directory, log)
            run([executables['vmap'], 'work', 'work'], directory, log)
            sources = sorted((root / 'src').glob('*.v')) + [root/'sim'/'tb_memory.sv',root/'sim'/'tb_all.sv',root/'sim'/'tb_fast_mapper.sv']
            manifest['source_sha256']={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
            run([executables['vlog'], '-sv', '-work', 'work', f'+incdir+{vectors.as_posix()}',
                 f'+define+TEST_USE_FAST_MAP={int(engine_map=="fast")}',
                 *[str(path) for path in sources]], directory, log)
            output = run([executables['vsim'], '-c', '-lib', 'work', 'tb_all', '-do',
                          'onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0'], directory, log)
            marker = f'ALL_RTL_TESTS_PASSED weight_frac={fraction} fast_engine={int(engine_map=="fast")}'
            if marker not in output:
                raise RuntimeError('Simulation ended without the required success marker.\n' + output)
            fast_output = run([executables['vsim'], '-c', '-lib', 'work', 'tb_fast_mapper', '-do',
                          'onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0'], directory, log)
            fast_marker = f'FAST_MAPPER_PASSED weight_frac={fraction}'
            if fast_marker not in fast_output:
                raise RuntimeError('Fast mapper simulation failed.\n' + fast_output)
            if any(hashlib.sha256(p.read_bytes()).hexdigest()!=manifest['source_sha256'][str(p.relative_to(root))] for p in sources):
                raise RuntimeError('Source files changed during simulation; rerun to verify the new source.')
            output += '\n' + fast_output
            manifest['passed'] = True
            manifest['elapsed_seconds'] = round(time.monotonic() - started, 3)
            manifest['simulation_results'] = [line for line in output.splitlines() if 'PASS ' in line or marker in line or fast_marker in line]
            reports.append(manifest)
            print('\n'.join(manifest['simulation_results']), flush=True)
        finally:
            (directory / 'simulation.log').write_text('\n'.join(log), encoding='utf-8')
    destination = root / 'out' / 'regression.json'
    destination.write_text(json.dumps(reports, indent=2), encoding='utf-8')
    print(f'Report: {destination}')


if __name__ == '__main__':
    main()
