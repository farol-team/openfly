import io,gzip,sys,tarfile,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'runtime'))
import workspace

class ArchiveSecurityTest(unittest.TestCase):
    def archive(self,entries):
        out=io.BytesIO()
        with tarfile.open(fileobj=out,mode='w:gz') as tar:
            for name,kind,target in entries:
                entry=tarfile.TarInfo(name);entry.mode=0o7777
                if kind=='file':
                    entry.size=len(target);tar.addfile(entry,io.BytesIO(target))
                else:
                    entry.type=kind;entry.linkname=target;tar.addfile(entry)
        return out.getvalue()
    def reject(self,entries):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):workspace.unpack(self.archive(entries),directory)
    def test_absolute_and_parent_traversal(self):
        for name in ['/tmp/outside','../outside','a/../../outside']:
            with self.subTest(name=name):self.reject([(name,'file',b'bad')])
    def test_duplicate_normalized_paths(self):
        self.reject([('a','file',b'1'),('./a','file',b'2')])
    def test_hard_links_and_devices_are_rejected(self):
        for kind in [tarfile.LNKTYPE,tarfile.CHRTYPE,tarfile.FIFOTYPE]:
            with self.subTest(kind=kind):self.reject([('bad',kind,'target')])
    def test_symlink_escape_and_descendant_writes(self):
        self.reject([('link',tarfile.SYMTYPE,'../../outside')])
        self.reject([('link',tarfile.SYMTYPE,'local'),('link/file','file',b'bad')])
    def test_expansion_limit_applies_before_tar_parsing(self):
        with tempfile.TemporaryDirectory() as directory,patch.object(workspace,'MAX_TAR_BYTES',100):
            with self.assertRaises(ValueError):workspace.unpack(gzip.compress(b'\0'*101),directory)
    def test_member_count_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory,patch.object(workspace,'MAX_ENTRIES',1):
            with self.assertRaises(ValueError):workspace.unpack(self.archive([('a','file',b'a'),('b','file',b'b')]),directory)
    def test_setuid_bits_are_removed_and_safe_link_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace.unpack(self.archive([('a','file',b'ok'),('link',tarfile.SYMTYPE,'a')]),directory)
            self.assertEqual((Path(directory)/'a').stat().st_mode & 0o7000,0)
            self.assertEqual((Path(directory)/'link').read_bytes(),b'ok')
    def test_nonempty_destination_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory)/'existing').write_text('keep')
            with self.assertRaises(ValueError):workspace.unpack(self.archive([('a','file',b'a')]),directory)
            self.assertEqual((Path(directory)/'existing').read_text(),'keep')
if __name__=='__main__':unittest.main()
