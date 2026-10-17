#!/usr/bin/env python3
"""Run native language processes in a private minimal app using the built app's resources."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import uuid
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--captures',type=Path);parser.add_argument('--locale',action='append',choices=['de','fr','en']);args=parser.parse_args()
root=Path(__file__).resolve().parent.parent;products=root/'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-languages-') as temporary:
    folder=Path(temporary);receiver=build_receiver(root,[root/'docs/qa/language-family-native-2026-10-17.swift'],folder)
    app=folder/'TurtleGitLanguageQA.app';binary=app/'Contents/MacOS/TurtleGitLanguageQA';binary.parent.mkdir(parents=True);shutil.copy2(receiver,binary)
    (app/'Contents/Resources').symlink_to(products/'TurtleGitMac.app/Contents/Resources',target_is_directory=True)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.turtlegit.macos.documentation-preview.language.'+uuid.uuid4().hex,'CFBundleExecutable':binary.name,'CFBundleName':'TurtleGit Language QA','CFBundlePackageType':'APPL','CFBundleDevelopmentRegion':'en'}))
    env=os.environ.copy();env['DYLD_FRAMEWORK_PATH']=str(products)
    for locale in args.locale or ['de','fr','en']:
        env.pop('TURTLEGIT_LANGUAGE_CAPTURE',None)
        if args.captures and locale=='de':env['TURTLEGIT_LANGUAGE_CAPTURE']=str(args.captures.resolve())
        print('Checking native app language '+locale,flush=True)
        result=run_receiver([str(binary),locale,'-AppleLanguages','('+locale+')'],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS language' not in result.stdout:raise SystemExit('Language receiver exited before its completion marker')
