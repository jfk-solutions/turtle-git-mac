#!/usr/bin/env python3
"""Inspect actual embedded service packaging; never registers a user launch job."""
import pathlib,plistlib,re,subprocess,sys
from finder_group_identity import mach_service
app=pathlib.Path(sys.argv[1]).resolve()
helper=app/'Contents/Library/LaunchServices/TurtleGitCache.app'
exe=helper/'Contents/MacOS/TurtleGitCache'
plist=plistlib.load(open(app/'Contents/Library/LaunchAgents/org.turtlegit.macos.cache.plist','rb'))
assert plist['Label']=='org.turtlegit.macos.cache'
app_signature=subprocess.run(['/usr/bin/codesign','-dv','--verbose=4',str(app)],capture_output=True,text=True)
match=re.search(r'^TeamIdentifier=([A-Z0-9]{10})$',app_signature.stderr,re.M)
team=match.group(1) if match else None
assert plist['MachServices']=={mach_service(team):True}
assert app/plist['BundleProgram']==exe
assert exe.is_file()
info=plistlib.load(open(helper/'Contents/Info.plist','rb'))
assert info['CFBundleIdentifier']=='org.turtlegit.macos.cache' and info['LSUIElement']
loads=subprocess.check_output(['/usr/bin/otool','-l',str(exe)],text=True)
assert '@executable_path/../../../../../Frameworks' in loads
for framework in ['TurtleGitCore.framework','TurtleGitSMTP.framework']:
 assert (app/'Contents/Frameworks'/framework).is_dir()
print('Embedded agent plist, executable, identity and containing-app framework paths passed. No launch job registered; signing/sandbox acceptance not inferred.')

# Only unsigned/ad-hoc products are launched by this negative fixture. Never start
# a real developer-signed service or use launchctl/SMAppService from this audit.
signing=subprocess.run(['/usr/bin/codesign','-dv','--verbose=4',str(helper)],capture_output=True,text=True)
if 'TeamIdentifier=not set' in signing.stderr or signing.returncode!=0:
 result=subprocess.run([str(exe)],capture_output=True,text=True,timeout=10)
 assert result.returncode==1 and 'TurtleGit cache service:' in result.stderr,result.stderr
 print('Unsigned helper refused startup; owned process exited/reaped. No user launch registration changed.')
else:
 print('Signed product: negative startup test skipped; real registration acceptance remains separate.')
