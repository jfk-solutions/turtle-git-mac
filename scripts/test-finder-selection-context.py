#!/usr/bin/env python3
"""Actual Finder menu source with owned compile/receiver; no Finder activation."""
from pathlib import Path
import platform
import tempfile
from native_receiver import run_receiver
root=Path(__file__).resolve().parent.parent
products=root/'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='TurtleGitFinderContext-') as temporary:
    directory=Path(temporary); binary=directory/'verify'; fixture=directory/'fixture'; fixture.mkdir()
    run_receiver(['xcrun','swiftc','-swift-version','6','-parse-as-library','-target',platform.machine()+'-apple-macos13.0','-F',str(products),'-framework','TurtleGitCore','-framework','FinderSync','-Xlinker','-rpath','-Xlinker',str(products),str(root/'FinderSync/FinderSync.swift'),str(root/'docs/qa/finder-selection-context-native-2026-10-15.swift'),'-o',str(binary)],cwd=root,check=True)
    run_receiver([str(binary),str(fixture)],cwd=root,check=True)
