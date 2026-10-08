from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from memory_profile import source_read_trace,cache_stats,traffic_bytes,profile
from reference import grid_point
from undistort import Camera,export_grid


class MemoryProfileTests(unittest.TestCase):
    def test_identity_trace_and_replicated_edges(self):
        y,x=np.indices((3,3))
        trace,mask=source_read_trace(x*256,y*256,(3,3))
        expected=[]
        for yy in range(3):
            for xx in range(3):
                expected += [yy*3+xx,yy*3+min(xx+1,2),min(yy+1,2)*3+xx,
                             min(yy+1,2)*3+min(xx+1,2)]
        self.assertEqual(trace.tolist(),expected)
        self.assertTrue(mask.all());self.assertEqual(trace[-4:].tolist(),[8]*4)

    def test_invalid_pixels_no_requests_and_fractional_neighbor(self):
        trace,mask=source_read_trace(np.array([[-1,257,513]]),np.array([[0,0,0]]),(3,3))
        self.assertEqual(mask.tolist(),[[False,True,False]])
        self.assertEqual(trace.tolist(),[1,2,4,5])
        empty,mask=source_read_trace(np.full((2,2),-1),np.zeros((2,2),int),(3,3))
        self.assertEqual(empty.size,0);self.assertFalse(mask.any())

    def test_coordinate_validation(self):
        for x,y,frac in (([[0.5]],[[0]],8),([[0]],[[0,0]],8),([[1<<31]],[[0]],8),([[0]],[[0]],0)):
            with self.assertRaises(ValueError):source_read_trace(x,y,(3,3),frac)

    def test_direct_conflicts_and_associative_reuse(self):
        # 2-byte lines: 0 and 2 conflict in a 2-set direct cache.
        direct=cache_stats([0,2,0],4,2,1)
        associative=cache_stats([0,2,0],4,2,2)
        self.assertEqual((direct['hits'],direct['misses']),(0,3))
        self.assertEqual((associative['hits'],associative['misses']),(1,2))

    def test_lru_replacement_and_repeat_compression(self):
        row=cache_stats([0,1,0,2,0,1,1,1],4,2,2)
        self.assertEqual((row['hits'],row['misses']),(4,4))
        self.assertEqual(row['miss_fill_bytes_per_frame'],8)
        same=cache_stats([0,1,2,3],8,8,1)
        self.assertEqual((same['hits'],same['misses']),(3,1))

    def test_random_trace_against_uncompressed_naive_lru(self):
        rng=np.random.default_rng(911)
        for ways in (1,2,4):
            trace=rng.integers(0,100,500)
            buckets=[[] for _ in range(4)];misses=0
            for address in trace:
                line=int(address)//4;bucket=buckets[line%4]
                if line in bucket:bucket.remove(line)
                else:
                    misses+=1
                    if len(bucket)==ways:bucket.pop(0)
                bucket.append(line)
            row=cache_stats(trace,8*ways*4,8,ways)
            self.assertEqual(row['misses'],misses)
            self.assertEqual(row['hits']+misses,500)

    def test_empty_and_invalid_cache_inputs(self):
        row=cache_stats([],32,32,1)
        self.assertEqual(row['misses'],0);self.assertIsNone(row['hit_fraction'])
        for addresses,capacity,line,ways in (([1.5],32,32,1),([-1],32,32,1),
            ([0],16,32,1),([0],32,1,1),([0],30,2,1),([0],32,2,3)):
            with self.assertRaises(ValueError):cache_stats(addresses,capacity,line,ways)

    def test_traffic_accounts_for_all_four_parts(self):
        result=traffic_bytes((3,3),(4,2),100)
        self.assertEqual(result['total_bytes_per_frame'],18+100+16+16)
        with self.assertRaises(ValueError):traffic_bytes((3,3),(4,2),-1)

    def test_exported_lut_profile_against_scalar_coordinates(self):
        c=Camera((35,19),[[30,0,17],[0,31,9],[0,0,1]],[-.1,.02,.001,0,0])
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary);export_grid(c,directory,32,8)
            from prepare_package import read_grid
            from reference import dense_grid
            metadata,grid=read_grid(directory)
            trace,mask=source_read_trace(*dense_grid(grid,c.size),c.size)
            expected=[]
            for y in range(19):
                for x in range(35):
                    sx,sy=grid_point(x,y,grid,c.size)
                    if 0<=sx<=34*256 and 0<=sy<=18*256:
                        x0,y0=sx//256,sy//256;x1,y1=min(x0+1,34),min(y0+1,18)
                        expected += [y0*35+x0,y0*35+x1,y1*35+x0,y1*35+x1]
            self.assertEqual(trace.tolist(),expected)
            report=profile(directory,capacities=(128,512),assumed_fps=60)
            self.assertEqual(report['logical_source_reads'],4*int(mask.sum()))
            self.assertEqual(len(report['configurations']),2)
            self.assertEqual(report['uncached_traffic']['assumed_MB_per_second'],
                             report['uncached_traffic']['total_bytes_per_frame']*60/1e6)
            with self.assertRaises(ValueError):profile(directory,assumed_fps=float('nan'))


if __name__=='__main__':unittest.main()
