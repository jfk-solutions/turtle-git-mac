#!/usr/bin/env python3
import csv
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('coverage',Path(__file__).with_name('reconcile-dialog-coverage.py'))
coverage=importlib.util.module_from_spec(spec);spec.loader.exec_module(coverage)

class DialogCoverageTests(unittest.TestCase):
    def fixture(self, root):
        (root/'docs/qa').mkdir(parents=True); (root/'Sources').mkdir()
        (root/'Sources/Fixture.swift').write_text('struct Fixture {}')
        (root/'docs/Fixture.md').write_text('IDD_FIXTURE partial behavior. See qa/fixture.json.')
        (root/'docs/qa/fixture.json').write_text('{}')
        (root/'docs/upstream.json').write_text(json.dumps({'commit':'pinned'}))
        def csv_file(name, rows):
            with (root/'docs'/name).open('w',newline='') as stream:
                writer=csv.DictWriter(stream,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
        csv_file('upstream-dialogs.csv',[{'resource':r,'id':'IDD_FIXTURE','caption':'Fixture','status':'pending-review'} for r in ['A.rc','B.rc']])
        csv_file('upstream-files.csv',[{'path':r,'blob':'blob-'+r} for r in ['A.rc','B.rc']])
        csv_file('upstream-controls.csv',[{'resource':r,'dialog':'IDD_FIXTURE','control':'IDC_TEXT','status':'pending-review','native_mapping':''} for r in ['A.rc','B.rc']])
        review={'upstream_commit':'pinned','reviews':[{'resource':'A.rc','id':'IDD_FIXTURE','status':'partial-native-replacement','native_sources':[{'path':'Sources/Fixture.swift','anchor':'struct Fixture'}],'parity_document':'docs/Fixture.md'}]}
        (root/'docs/dialog-coverage-reviews.json').write_text(json.dumps(review)); return review

    def test_partial_family_does_not_clear_controls_or_certify_parity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);self.fixture(root)
            dialogs,ledger,text=coverage.reconcile(root)
            self.assertEqual(ledger['summary']['partial_family_audits'],1)
            self.assertEqual(ledger['summary']['pending_control_reviews'],2)
            self.assertEqual(ledger['summary']['certified_complete'],0)
            self.assertTrue(all(not row['certified_complete'] for row in ledger['dialogs']))
            self.assertEqual(ledger['dialogs'][0]['qa_records'],['docs/qa/fixture.json'])
            # Same resource ID in a different component must not inherit evidence.
            self.assertEqual(ledger['dialogs'][1]['parity_documents'],[])
            self.assertEqual(dialogs[1]['status'],'pending-review')

    def test_repin_unknown_review_and_complete_claim_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);review=self.fixture(root);path=root/'docs/dialog-coverage-reviews.json'
            for field,value in [('upstream_commit','different'),('id','IDD_UNKNOWN'),('status','complete'),('status','partial-complete')]:
                changed=json.loads(json.dumps(review))
                if field=='upstream_commit':changed[field]=value
                else:changed['reviews'][0][field]=value
                path.write_text(json.dumps(changed))
                with self.assertRaises(ValueError):coverage.reconcile(root)

    def test_missing_native_reference_is_not_accepted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);self.fixture(root);(root/'Sources/Fixture.swift').unlink()
            with self.assertRaises(ValueError):coverage.reconcile(root)

if __name__=='__main__':unittest.main()
