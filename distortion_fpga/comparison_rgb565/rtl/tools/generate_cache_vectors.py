"""Generate cold-frame address sequences and independent exact cache counts."""
import argparse
import json
from pathlib import Path
import sys

import numpy as np

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'algorithm'))
from memory_profile import cache_stats


def generate(out,line_log2=4,set_log2=3):
    if (type(line_log2) is not int or type(set_log2) is not int or not 1<=line_log2<=8 or not 1<=set_log2<=10):
        raise ValueError('test-vector line_log2 must be 1..8 and set_log2 1..10')
    out=Path(out);out.mkdir(parents=True,exist_ok=True)
    lp=1<<line_log2;sets=1<<set_log2;capacity=2*sets*lp*2
    rng=np.random.default_rng(20261007)
    pixels=max(2048,16*sets*lp)
    conflict=np.array([0,sets*lp,0,2*sets*lp,0,sets*lp,lp-1,lp-1,pixels-1],np.int64)
    coherent=np.repeat(np.arange(512),4)
    random=rng.integers(0,pixels,2048)
    # More same-set lines than ways exercise replacement, not only cold misses.
    collisions=rng.integers(0,16,1024)*sets*lp+rng.integers(0,lp,1024)
    addresses=np.r_[conflict,coherent,random,collisions,conflict]
    stats=cache_stats(addresses,capacity,line_bytes=lp*2,ways=2)
    (out/'addresses.memh').write_text(''.join(f'{int(a):06x}\n' for a in addresses),encoding='ascii')
    macros={'COUNT':len(addresses),'LINE_LOG2':line_log2,'SET_LOG2':set_log2,
            'HITS':stats['hits'],'MISSES':stats['misses'],'PIXELS':pixels}
    (out/'cache_vectors.vh').write_text(''.join(f'`define CACHE_{k} {v}\n' for k,v in macros.items()),encoding='ascii')
    result={'seed':20261007,'parameters':macros,'cache':stats,
            'scope':'Artificial logical pixel trace; compare two-way LRU RTL counters and every returned pixel.'}
    (out/'vectors.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--line-log2',type=int,default=4);p.add_argument('--set-log2',type=int,default=3)
    args=p.parse_args();print(json.dumps(generate(args.out,args.line_log2,args.set_log2),indent=2))
