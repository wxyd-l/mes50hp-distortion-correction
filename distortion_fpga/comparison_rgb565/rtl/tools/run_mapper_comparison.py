"""Execute formula/Q8-grid/Q16-grid against the SAME generated input package."""
import argparse
import hashlib
import json
from pathlib import Path

from run_formula_sim import simulate as simulate_formula,validate_package,ROOT
from run_package_sim import simulate as simulate_grid


def existing_result(package,is_formula):
    data=json.loads((package/'package.json').read_text(encoding='utf-8'))
    for name,digest in data['sha256'].items():
        if Path(name).name!=name or hashlib.sha256((package/name).read_bytes()).hexdigest()!=digest:
            raise ValueError('cannot summarize altered package')
    identity=hashlib.sha256((package/'package.json').read_bytes()).hexdigest()[:12]
    name=f'formula-{identity}' if is_formula else f'package-{identity}-fast-cachel4s9'
    result=json.loads((ROOT/'rtl/out'/name/'result.json').read_text(encoding='utf-8'))
    if result.get('passed') is not True or Path(result['package']).resolve()!=package.resolve() or not result.get('source_sha256'):
        raise ValueError('no matching passed report')
    for base,hashes in ((ROOT/'rtl',result['source_sha256']),(ROOT/'algorithm',result.get('algorithm_source_sha256',{}))):
        for relative,digest in hashes.items():
            target=(base/relative).resolve()
            if not target.is_relative_to(base) or hashlib.sha256(target.read_bytes()).hexdigest()!=digest:
                raise ValueError('cannot summarize stale source report')
    if not is_formula and (result.get('fast_mapper') is not True or result.get('cache_enabled') is not True):
        raise ValueError('grid report did not use the comparison configuration')
    return result


def run(directory,summary_only=False):
    directory=Path(directory).resolve()
    formula,_=validate_package(directory/'formula')
    grid=[]
    for name in ('grid_q8_package','grid_q16_package'):
        package=json.loads((directory/name/'package.json').read_text(encoding='utf-8'))
        if (package['sha256']['source_rgb565.memh']!=formula['sha256']['source_rgb565.memh'] or
                [package['parameters']['SRC_WIDTH'],package['parameters']['SRC_HEIGHT']]!=formula['input_size'] or
                [package['parameters']['OUT_WIDTH'],package['parameters']['OUT_HEIGHT']]!=formula['output_size']):
            raise ValueError('comparison packages do not share source frame and dimensions')
        grid.append(directory/name)
    if summary_only:
        results={'formula_q16':existing_result(directory/'formula',True),
                 'grid_q8':existing_result(grid[0],False),'grid_q16':existing_result(grid[1],False)}
    else:
        results={'formula_q16':simulate_formula(directory/'formula'),
                 'grid_q8':simulate_grid(grid[0],fast_map=True,cache=True),
                 'grid_q16':simulate_grid(grid[1],fast_map=True,cache=True)}
    report={'all_passed':all(result['passed'] for result in results.values()),'results':results,
            'same_source_rgb565_sha256':formula['sha256']['source_rgb565.memh'],
            'scope':'Each RTL branch matches its own integer oracle. Branch outputs need not be identical. '
                    'All share RGB565, whole-sample black/replicated border and the same artificial line backend. '
                    'Simulation cycles are not board clock, memory timing or fps; use comparison.json for numeric errors.'}
    (directory/'rtl_comparison.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    return report


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--directory',type=Path,required=True)
    p.add_argument('--summarize',action='store_true',help='only combine existing matching source/package reports; do not simulate')
    args=p.parse_args();print(json.dumps(run(args.directory,args.summarize),indent=2))
