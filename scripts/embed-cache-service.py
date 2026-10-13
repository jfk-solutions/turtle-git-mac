#!/usr/bin/env python3
"""Embed the separately sandboxed, signed agent without modifying its contents."""
import os,pathlib,shutil,subprocess,sys
helper,app,configuration=map(pathlib.Path,sys.argv[1:])
if not (helper/'Contents/MacOS/TurtleGitCache').is_file():raise SystemExit('Missing Finder cache service build product')
services=app/'Contents/Library/LaunchServices'
services.mkdir(parents=True,exist_ok=True)
destination=services/helper.name
if destination.exists():shutil.rmtree(destination)
subprocess.run(['/usr/bin/ditto',str(helper),str(destination)],check=True)
launch=app/'Contents/Library/LaunchAgents'
launch.mkdir(parents=True,exist_ok=True)
shutil.copy2(configuration,launch/configuration.name)
# Build product signing must match the container. Copy preserves its signature;
# Xcode signs the containing app after this phase.
