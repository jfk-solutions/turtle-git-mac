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
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--captures',type=Path);parser.add_argument('--only',action='append',choices=['settings','files','history']);parser.add_argument('--locale',action='append',choices=['de','fr','en']);parser.add_argument('--git',type=Path,action='append');args=parser.parse_args()
root=Path(__file__).resolve().parent.parent;products=root/'build/Build/Products/Debug'
cases=args.only or ['settings','files','history']
functions={'settings':'LanguageFamilyVerification.main()','files':'FileListLanguagesVerification.verify()','history':'HistoryLocalizationVerification.verify()'}
with tempfile.TemporaryDirectory(prefix='turtlegit-languages-') as temporary:
    folder=Path(temporary)
    settings=folder/'LanguageSettings.swift';settings.write_text((root/'docs/qa/language-family-native-2026-10-17.swift').read_text().replace('@main ', '',1))
    main=folder/'LanguageMain.swift';main.write_text('import AppKit\n@main struct LanguageMain { @MainActor static func main() async throws { NSApp.setActivationPolicy(.prohibited);switch ProcessInfo.processInfo.environment["TURTLEGIT_LANGUAGE_CASE"] { '+''.join('case "'+case+'":try await '+functions[case]+';' for case in cases)+'default:fatalError("Unknown language case")} } }\n')
    fixtures=[]
    if 'settings' in cases:fixtures.append(settings)
    if 'files' in cases:fixtures.append(root/'docs/qa/file-list-languages-native-2026-10-17.swift')
    if 'history' in cases:fixtures.append(root/'docs/qa/history-localization-native-2026-11-01.swift')
    receiver=build_receiver(root,[*fixtures,main],folder)
    app=folder/'TurtleGitLanguageQA.app';binary=app/'Contents/MacOS/TurtleGitLanguageQA';binary.parent.mkdir(parents=True);shutil.copy2(receiver,binary)
    (app/'Contents/Resources').symlink_to(products/'TurtleGitMac.app/Contents/Resources',target_is_directory=True)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.turtlegit.macos.documentation-preview.language.'+uuid.uuid4().hex,'CFBundleExecutable':binary.name,'CFBundleName':'TurtleGit Language QA','CFBundlePackageType':'APPL','CFBundleDevelopmentRegion':'en'}))
    env={key:value for key,value in os.environ.items() if not key.startswith('GIT_')};env.update(DYLD_FRAMEWORK_PATH=str(products),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case in cases:
        env['TURTLEGIT_LANGUAGE_CASE']=case
        for locale in args.locale or ['de','fr','en']:
            env.pop('TURTLEGIT_LANGUAGE_CAPTURE',None)
            if args.captures and locale=='de':env['TURTLEGIT_LANGUAGE_CAPTURE']=str(args.captures.resolve())
            engines=(args.git or [Path('/usr/bin/git')]) if case=='history' else [None]
            for index,git in enumerate(engines):
                isolated=folder/(case+'-'+locale+'-'+str(index));isolated.mkdir(mode=0o700)
                for name in ['home','temporary','xdg','repository']:(isolated/name).mkdir(mode=0o700)
                (isolated/'home/Library/Preferences').mkdir(parents=True,mode=0o700)
                env.update(HOME=str(isolated/'home'),CFFIXED_USER_HOME=str(isolated/'home'),TMPDIR=str(isolated/'temporary')+'/',XDG_CONFIG_HOME=str(isolated/'xdg'))
                command=[str(binary),locale]
                if git is not None:command += [str(isolated/'repository'),str(git.absolute())]
                command += ['-AppleLanguages','('+locale+')']
                print('Checking native app language '+case+' '+locale+(' '+str(git) if git is not None else ''),flush=True)
                result=run_receiver(command,cwd=root,env=env,capture_output=True,text=True)
                print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
                if 'PASS language' not in result.stdout:raise SystemExit('Language receiver exited before its completion marker')
