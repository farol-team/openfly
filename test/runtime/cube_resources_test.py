import sys,unittest
from pathlib import Path
from types import SimpleNamespace
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'runtime'))
from provider import Cube
class CubeResourcesTest(unittest.TestCase):
    def check(self,reported,actual=30*1024**3,cpu=2,memory=4096):
        cube=object.__new__(Cube)
        cube.cmd=lambda command,root: str(actual)
        cube.validate_resources(SimpleNamespace(cpu_count=cpu,memory_mb=memory,disk_size_mb=reported),{'vcpus':2,'memory_mib':4096,'disk_mib':30720})
    def test_zero_and_absent_require_exact_real_capacity(self):
        for reported in (None,0):
            self.check(reported)
            with self.assertRaises(RuntimeError):self.check(reported,actual=20*1024**3)
    def test_reported_mismatch_is_not_bypassed(self):
        self.check(30720)
        with self.assertRaises(RuntimeError):self.check(1024)
    def test_cpu_and_memory_mismatch_fail(self):
        with self.assertRaises(RuntimeError):self.check(0,cpu=4)
        with self.assertRaises(RuntimeError):self.check(0,memory=2048)
    def test_unavailable_probe_fails_closed(self):
        with self.assertRaises(ValueError):self.check(0,actual='')
if __name__=='__main__':unittest.main()
