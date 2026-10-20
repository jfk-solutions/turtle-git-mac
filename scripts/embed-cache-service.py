#!/usr/bin/env python3
"""Embed the separately sandboxed, signed agent without modifying its contents."""
import os,pathlib,plistlib,shutil,subprocess,sys
from finder_group_identity import mach_service,query_mach_service
helper,app,configuration=map(pathlib.Path,sys.argv[1:])
if not (helper/'Contents/MacOS/TurtleGitCache').is_file():raise SystemExit('Missing Finder cache service build product')
services=app/'Contents/Library/LaunchServices'
services.mkdir(parents=True,exist_ok=True)
destination=services/helper.name
if destination.exists():shutil.rmtree(destination)
subprocess.run(['/usr/bin/ditto',str(helper),str(destination)],check=True)
launch=app/'Contents/Library/LaunchAgents'
launch.mkdir(parents=True,exist_ok=True)
definition=plistlib.loads(configuration.read_bytes())
if definition.get('MachServices') != {'$(TeamIdentifierPrefix)org.turtlegit.macos.cache':True,'$(TeamIdentifierPrefix)org.turtlegit.macos.cache.query':True}:
    raise SystemExit('Unexpected cache service namespace template')
definition['MachServices']={mach_service(os.environ.get('DEVELOPMENT_TEAM','')):True,query_mach_service(os.environ.get('DEVELOPMENT_TEAM','')):True}
(launch/configuration.name).write_bytes(plistlib.dumps(definition,sort_keys=False))
# Build product signing must match the container. Copy preserves its signature;
# Xcode signs the containing app after this phase.
