"""Generate passive Quit-worker diagnostics for the existing owner fixtures."""
import json
from pathlib import Path
import re


def write_quit_admission_diagnostics(root: Path, generated: Path) -> Path:
    # Derive every static active-work counter from the actual termination
    # consumer. Reading counters has no Quit/routing/presentation side effects.
    application = (root/'Sources/TurtleGitMac/ApplicationDelegate.swift').read_text()
    termination = application[application.index('    func applicationShouldTerminate('):application.index('    private func finishDedicatedUnifiedDiffAfterApprovedQuit')]
    counters = sorted(set(re.findall(r'\b[A-Z]\w*(?:\.[A-Za-z_]\w*)*\.active\w+', termination)))
    if not counters:
        raise RuntimeError('Native Quit admission counter inventory is empty')
    source = generated/'QuitAdmissionDiagnostics.swift'
    source.write_text('import AppKit\n@testable import TurtleGitMac\n@MainActor extension WorkspaceOwnerVerification {\n static func quitWorkerCounters()->[(String,Int)] {\n  var result:[(String,Int)]=[]\n'
        + ''.join('  result.append(('+json.dumps(value)+',Int('+value+')))\n' for value in counters)
        + '  return result\n }\n}\n')
    return source
