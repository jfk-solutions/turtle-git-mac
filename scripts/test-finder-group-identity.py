#!/usr/bin/env python3
"""Offline contracts for macOS team-qualified group and launch-agent production."""
import os,plistlib,subprocess,tempfile,unittest
from pathlib import Path
from finder_group_identity import app_group,mach_service
ROOT=Path(__file__).resolve().parent.parent

class FinderGroupIdentityTests(unittest.TestCase):
    def test_team_qualification_and_unsigned_diagnostic(self):
        self.assertEqual(app_group('ABCDE12345'),'ABCDE12345.org.turtlegit.macos')
        self.assertEqual(mach_service('ABCDE12345'),'ABCDE12345.org.turtlegit.macos.cache')
        self.assertEqual(app_group(None),'org.turtlegit.macos')
        self.assertEqual(mach_service(''),'org.turtlegit.macos.cache')
    def test_invalid_team_cannot_become_a_namespace(self):
        for value in ['adhoc','abcde12345','ABCDE1234"','ABCDE123456','ABCDE/2345',' ABCDE1234']:
            with self.assertRaises(ValueError):app_group(value)
    def test_all_three_peers_and_both_app_channels_share_the_template(self):
        for name in ['App.entitlements','AppStore.entitlements','Finder.entitlements','Cache.entitlements']:
            value=plistlib.loads((ROOT/'Configuration'/name).read_bytes())
            self.assertEqual(value['com.apple.security.application-groups'],['$(TeamIdentifierPrefix)org.turtlegit.macos'])
        agent=plistlib.loads((ROOT/'Configuration/org.turtlegit.macos.cache.plist').read_bytes())
        self.assertEqual(agent['MachServices'],{'$(TeamIdentifierPrefix)org.turtlegit.macos.cache':True})
    def test_embed_expands_namespace_and_preserves_the_helper(self):
        with tempfile.TemporaryDirectory(prefix='tg-group-') as directory:
            folder=Path(directory);helper=folder/'TurtleGitCache.app';binary=helper/'Contents/MacOS/TurtleGitCache'
            binary.parent.mkdir(parents=True);binary.write_bytes(b'owned unsigned fixture, never executed')
            for team in ['ABCDE12345','']:
                app=folder/('Signed.app' if team else 'Unsigned.app')
                env=dict(os.environ,DEVELOPMENT_TEAM=team)
                subprocess.run(['python3',str(ROOT/'scripts/embed-cache-service.py'),str(helper),str(app),str(ROOT/'Configuration/org.turtlegit.macos.cache.plist')],env=env,check=True)
                agent=plistlib.loads((app/'Contents/Library/LaunchAgents/org.turtlegit.macos.cache.plist').read_bytes())
                self.assertEqual(agent['MachServices'],{mach_service(team):True})
                self.assertEqual(agent['Label'],'org.turtlegit.macos.cache')
                self.assertEqual((app/'Contents/Library/LaunchServices/TurtleGitCache.app/Contents/MacOS/TurtleGitCache').read_bytes(),binary.read_bytes())

if __name__=='__main__':unittest.main()
