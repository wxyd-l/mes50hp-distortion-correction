"""Run real Icarus simulations, using a native install or project-local WSL tools."""
from pathlib import Path
import argparse
import json
import os
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def execute(cmd, timeout=180):
    print('> ' + ' '.join(str(x) for x in cmd), flush=True)
    result = subprocess.run(cmd, cwd=ROOT, text=True, encoding='utf-8',
                            errors='replace', capture_output=True, timeout=timeout)
    print(result.stdout, end='')
    if result.stderr:
        print(result.stderr, end='', file=sys.stderr)
    if result.returncode:
        raise RuntimeError(f'Command failed with exit code {result.returncode}')
    return result.stdout


def wsl_path(path):
    path = Path(path).resolve()
    drive = path.drive[0].lower()
    return '/mnt/' + drive + '/' + path.as_posix()[3:]


def run(top, bench, rtl_files, defines=()):
    output = ROOT / 'build' / (top + '.vvp')
    native = shutil.which('iverilog')
    vvp = shutil.which('vvp')
    args = ['-g2012', '-Wall'] + ['-D'+d for d in defines] + ['-s', top, '-o', str(output), str(ROOT / bench)]
    args += [str(ROOT / item) for item in rtl_files]
    if native and vvp:
        execute([native] + args)
        return execute([vvp, str(output)], timeout=240)
    if os.name == 'nt':
        distro = os.environ.get('FPGA_WSL_DISTRO', 'Ubuntu-22.04')
        local = ROOT / 'tools' / 'iverilog-wsl' / 'usr'
        if not (local / 'bin' / 'iverilog').exists():
            raise RuntimeError('No Icarus installation: see docs/tool_setup.md')
        wargs = ['-g2012', '-Wall'] + ['-D'+d for d in defines] + ['-s', top, '-o', wsl_path(output), wsl_path(ROOT / bench)]
        wargs += [wsl_path(ROOT / item) for item in rtl_files]
        execute(['wsl', '-d', distro, '--', wsl_path(local / 'bin' / 'iverilog'),
                 '-B', wsl_path(local / 'lib' / 'x86_64-linux-gnu' / 'ivl')] + wargs)
        # WSL inherits cwd from this process: build/*.hex paths in benches stay relative.
        return execute(['wsl', '-d', distro, '--', wsl_path(local / 'bin' / 'vvp'),
                        wsl_path(output)], timeout=240)
    raise RuntimeError('Install iverilog and vvp or see docs/tool_setup.md')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--only', choices=['math', 'frame', 'vectors', 'cache', 'bridge', 'cached-frame'])
    args = parser.parse_args()
    (ROOT / 'build').mkdir(exist_ok=True)
    common = ['rtl/distortion_mapper.sv', 'rtl/bilinear_rgb.sv']
    jobs = [('math', 'tb_math', 'sim/tb_math.sv', common, ()),
            ('vectors', 'tb_vectors', 'sim/tb_vectors.sv', common, ()),
            ('frame', 'tb_frame', 'sim/tb_frame.sv', common + ['rtl/remap_frame_core.sv'], ()),
            ('cache', 'tb_pixel_read_cache', 'sim/tb_pixel_read_cache.sv', ['rtl/pixel_read_cache.sv'], ()),
            ('bridge', 'tb_pango_read_bridge', 'sim/tb_pango_read_bridge.sv', ['rtl/pango_read_bridge.sv'], ()),
            ('cached-frame', 'tb_frame_cached', 'sim/tb_frame.sv', common +
             ['rtl/remap_frame_core.sv', 'rtl/pixel_read_cache.sv', 'rtl/pango_read_bridge.sv', 'rtl/remap_ddr_read_top.sv'], ('DDR_CACHE',))]
    report = []
    for label, top, bench, sources, defines in jobs:
        if args.only and args.only != label:
            continue
        started = time.monotonic()
        log = run(top, bench, sources, defines)
        if 'PASS' not in log or 'FAIL' in log or 'FATAL' in log:
            raise RuntimeError(f'{top} did not report an unambiguous PASS')
        (ROOT / 'build' / f'{top}.log').write_text(log, encoding='utf-8')
        report.append({'test': top, 'passed': True, 'seconds': round(time.monotonic()-started, 3)})
    (ROOT / 'build' / ('hdl_results' + ('_' + args.only if args.only else '') + '.json')).write_text(
        json.dumps({'kind': 'RTL functional simulation; not board timing', 'tests': report}, indent=2),
        encoding='utf-8')


if __name__ == '__main__':
    main()
