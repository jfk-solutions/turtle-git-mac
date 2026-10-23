#!/usr/bin/env python3
"""Grouped native source-text patch discovery, review, apply, original bytes and ownership."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
from native_receiver import build_receiver, run_receiver


def retire_owned_helpers(context, images):
    """Require an approved Git/shell image AND an open private fixture path.

    The Bash allowance covers only this fixture's held discovery wrapper; a
    shell without an open file beneath this private context is never selected.
    """
    def owned():
        result = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(context)],
                                capture_output=True, text=True, timeout=10)
        if result.returncode not in (0, 1):
            raise RuntimeError('Cannot inspect private source patch helper ownership')
        matches = []
        for value in set(result.stdout.split()):
            pid = int(value)
            image = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-Fn'],
                                   capture_output=True, text=True, timeout=5)
            paths = {str(Path(line[1:]).resolve()) for line in image.stdout.splitlines() if line.startswith('n')}
            if paths.intersection(images):
                matches.append(pid)
        return matches
    needed = bool(owned())
    for number in (signal.SIGTERM, signal.SIGKILL):
        for pid in owned():
            if pid not in owned():
                continue
            try:
                group = os.getpgid(pid)
                os.killpg(group, number) if group == pid else os.kill(pid, number)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        while owned() and time.monotonic() < deadline:
            time.sleep(.03)
        if not owned():
            return needed
    raise RuntimeError('Verified private Git/shell helper survived source patch cleanup')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['workflow', 'svn', 'lifecycle'], action='append')
parser.add_argument('--capture-dir', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
generated = root / 'build/qa/source-text-patch-family-native-sources'
generated.mkdir(parents=True, exist_ok=True)
main = generated / 'SourceTextPatchMain.swift'
source = '''import AppKit
import ObjectiveC
import ScreenCaptureKit
import TurtleGitCore
enum SourcePatchCapture {
    struct Failure:Error {let message:String}
    @MainActor static func save(_ window:NSWindow,_ name:String) async throws {
        guard let path=ProcessInfo.processInfo.environment["TURTLEGIT_SOURCE_TEXT_PATCH_CAPTURES"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(message:"Current-process compositor capture unavailable")}
        let oldAppearance=window.appearance,oldAlpha=window.alphaValue
        defer{window.appearance=oldAppearance;window.alphaValue=oldAlpha}
        for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);window.orderFront(nil);window.alphaValue=1
            window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:200_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(message:"Owned window unavailable to compositor")}
            let configuration=SCStreamConfiguration();configuration.width=Int(window.frame.width*2);configuration.height=Int(window.frame.height*2)
            configuration.showsCursor=false;configuration.ignoreShadowsSingleWindow=true;configuration.includeChildWindows=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:configuration)
            guard let bytes=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else{throw Failure(message:"Native capture PNG unavailable")}
            let filename=name+"-"+suffix+".png"
            try bytes.write(to:URL(fileURLWithPath:path).appendingPathComponent(filename))
            print("Owned native capture: "+filename+" "+String(pixels.width)+"x"+String(pixels.height))
        }
    }
}
private extension NSWindow {
    @objc func turtleGitSourcePatchOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000));turtleGitSourcePatchOrder(place,relativeTo:number)
    }
}
@main struct SourceTextPatchMain {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
        let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitSourcePatchOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden)
        defer{method_exchangeImplementations(original,hidden)}
        let suite="TurtleGit.SourcePatch.Geometry."+UUID().uuidString
        let preferences=UserDefaults(suiteName:suite)!
        DialogGeometry.install(preferences:preferences)
        defer{DialogGeometry.install(preferences:.standard);preferences.removePersistentDomain(forName:suite)}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        try await SourceTextPatchNativeVerification.run(root:root,git:git,kind:ProcessInfo.processInfo.environment["TURTLEGIT_SOURCE_TEXT_PATCH_CASE"]!)
        print("PASS: Source text patch family case completed")
    }
}
'''
if not main.is_file() or main.read_text() != source:
    main.write_text(source)
fixtures = [root / 'docs/qa/source-text-patch-native-2026-10-23.swift']
receiver = build_receiver(root, [*fixtures, main], generated)
engines = args.git or [Path('/usr/bin/git')]
system_git = subprocess.check_output(['/usr/bin/xcrun', '--find', 'git'], text=True).strip()
images = {str(path.resolve()) for path in [*engines, Path(system_git), root / 'build/git-runtime/Git/bin/git', Path('/bin/bash')] if path.is_file()}
with tempfile.TemporaryDirectory(prefix='turtlegit-source-text-patch-family-') as temporary:
    for case in args.only or ['workflow', 'svn', 'lifecycle']:
        for index, git in enumerate(engines):
            context = Path(temporary) / (case + str(index)); context.mkdir(mode=0o700)
            paths = {name: context / name for name in ['fixture', 'home', 'temporary', 'xdg']}
            for path in paths.values():
                path.mkdir(mode=0o700)
            config = context / 'global.config'; config.write_text('')
            env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            env.update(DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
                       GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                       HOME=str(paths['home']), CFFIXED_USER_HOME=str(paths['home']),
                       XDG_CONFIG_HOME=str(paths['xdg']), TMPDIR=str(paths['temporary'])+'/',
                       TURTLEGIT_SOURCE_TEXT_PATCH_CASE=case)
            env.pop('TURTLEGIT_SOURCE_TEXT_PATCH_CAPTURES', None)
            if args.capture_dir and index == 0:
                args.capture_dir.mkdir(parents=True, exist_ok=True)
                env['TURTLEGIT_SOURCE_TEXT_PATCH_CAPTURES'] = str(args.capture_dir.resolve())
            print('Checking source text patch family '+case+' with '+str(git), flush=True)
            completed = False
            try:
                result = run_receiver([str(receiver), str(paths['fixture']), str(git.absolute())],
                                      cwd=root, env=env, capture_output=True, text=True,
                                      timeout_sample=root / ('build/qa/source-text-patch-family-'+case+'-'+str(index)+'.sample.txt'))
                print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
                if 'PASS: Source text patch family case completed' not in result.stdout:
                    raise SystemExit('Primary parity receiver exited before completion')
                completed = True
            finally:
                if retire_owned_helpers(context, images) and completed:
                    raise RuntimeError('Completed source patch case left a test-owned Git/shell helper alive')
