import json,subprocess,sys,unittest
from pathlib import Path
class ProviderDiagnosticsTest(unittest.TestCase):
    def test_provider_exception_does_not_expose_secret_path(self):
        secret='fixture-secret-not-for-logs'
        payload={'action':'create','node':{'provider':'cubesandbox','config':{'environment_file':'/absent/'+secret}}}
        result=subprocess.run([sys.executable,str(Path(__file__).resolve().parents[2]/'runtime/provider.py')],input=json.dumps(payload),text=True,capture_output=True)
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn(secret,result.stdout+result.stderr)
        data=json.loads(result.stdout)['data']
        self.assertEqual(data['code'],'provider_initialize_failed')
        self.assertGreaterEqual(data['duration_ms'],0)
if __name__=='__main__':unittest.main()
