#!/usr/bin/env python3
"""External UDiff and Alternative Editor app/executable workflows; no user apps."""
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-external-documents-') as temporary:
    folder=Path(temporary);inputs=root/'build/qa/external-document-fixtures';inputs.mkdir(parents=True,exist_ok=True)
    source=inputs/'external-documents-native-2026-10-15.swift'
    source.write_text((root/'docs/qa'/source.name).read_text())
    receiver=build_receiver(root,[source],folder)
    fixture=folder/'files';fixture.mkdir()
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1')
    result=run_receiver([str(receiver),str(fixture)],cwd=root,env=env,capture_output=True,text=True)
    print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
    if 'PASS: External document templates/' not in result.stdout:raise SystemExit('External document receiver exited before completion.')
