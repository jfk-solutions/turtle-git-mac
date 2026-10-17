#!/usr/bin/env python3
"""Exercise real unsigned, ordinary and inherited Lexilla signing branches."""
import hashlib,json,os,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
RUNTIME=ROOT/'build/lexilla-runtime/Lexilla'

class LexillaEmbeddingTests(unittest.TestCase):
    def test_signing_modes_preserve_unsigned_execution_and_audit_inheritance(self):
        unsigned=json.loads((RUNTIME/'provenance.json').read_text())['files']['lexilla']
        with tempfile.TemporaryDirectory(prefix='tg-lexilla-signing-') as temporary:
            for mode,enabled,inherited in [('Unsigned',False,False),('Debug',True,False),('AppStore',True,True)]:
                app=Path(temporary)/(mode+'.app');(app/'Contents').mkdir(parents=True)
                env=dict(os.environ,CONFIGURATION=mode,CODE_SIGNING_ALLOWED='YES' if enabled else 'NO',EXPANDED_CODE_SIGN_IDENTITY='-')
                subprocess.run(['python3',str(ROOT/'scripts/embed-lexilla-runtime.py'),str(RUNTIME),str(app)],env=env,check=True,capture_output=True,text=True)
                target=app/'Contents/Helpers/Lexilla';manifest=json.loads((target/'provenance.json').read_text())
                self.assertEqual(manifest['files']['lexilla'],hashlib.sha256((target/'lexilla').read_bytes()).hexdigest())
                if enabled:
                    self.assertIs(manifest['signed'],True);self.assertEqual(manifest['unsigned_binary_sha256'],unsigned)
                    self.assertEqual(manifest['sandbox_inherited'],inherited)
                else:self.assertEqual(manifest['files']['lexilla'],unsigned)
                # Corrupt inherited metadata must fail, never silently drop its
                # signature audit or launch an inherited child from Python.
                if inherited:
                    manifest['signed']=False;(target/'provenance.json').write_text(json.dumps(manifest))
                    result=subprocess.run(['python3',str(ROOT/'scripts/validate-lexilla-runtime.py'),str(target)],capture_output=True,text=True)
                    self.assertEqual(result.returncode,1);self.assertIn('Inherited Lexilla manifest must record signing',result.stderr)

if __name__=='__main__':unittest.main()
