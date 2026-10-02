"""Rebuild fixtures and run software + real RTL regression; never substitutes mocks for RTL."""
from pathlib import Path
import argparse
from datetime import datetime, timezone, timedelta
import hashlib
import json
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def command(*args):
    print('> ' + ' '.join(args), flush=True)
    subprocess.run([sys.executable, *args], cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--software-only', action='store_true', help='explicitly skip RTL; report records it')
    parser.add_argument('--synthesis', action='store_true', help='also run optional generic Yosys check')
    args = parser.parse_args()
    import cv2
    import numpy
    suite = unittest.defaultTestLoader.discover(str(ROOT/'tests'), pattern='test_*.py')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        raise SystemExit(1)
    command('scripts/generate_regression.py')
    command('-m','software.cli','demo','--output','build/synthetic_demo')
    command('-m','software.cli','roundtrip','--output','build/synthetic_roundtrip')
    if not args.software_only:
        command('scripts/run_hdl.py')
    if args.synthesis:
        command('scripts/check_synthesis.py')
    files = sorted(p for folder in ('rtl','software','scripts','sim','tests')
                   for p in (ROOT/folder).rglob('*') if p.suffix in ('.sv','.py'))
    hashes = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    report = {
        'verified_at': datetime.now(timezone(timedelta(hours=8))).isoformat(timespec='seconds'),
        'scope': 'offline functional verification; not PDS timing or hardware validation',
        'python': sys.version.split()[0], 'numpy': numpy.__version__, 'opencv': cv2.__version__,
        'software_tests_run': result.testsRun, 'software_passed': True,
        'hdl_run': not args.software_only, 'generic_synthesis_requested': args.synthesis,
        'source_sha256': hashes,
    }
    if not args.software_only:
        report['hdl'] = json.loads((ROOT/'build/hdl_results.json').read_text(encoding='utf-8'))
    output = ROOT/'reports/latest_verification.json'
    output.parent.mkdir(exist_ok=True)
    output.write_text(json.dumps(report, indent=2, ensure_ascii=False)+'\n', encoding='utf-8')
    print(f'PASS: reproducible offline verification complete. Report: {output}')


if __name__ == '__main__':
    main()
