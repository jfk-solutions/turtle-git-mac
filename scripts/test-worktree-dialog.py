#!/usr/bin/env python3
"""Run the complete native Worktree family through the cached owned receiver."""
import subprocess
import sys
from pathlib import Path
root=Path(__file__).resolve().parent.parent
raise SystemExit(subprocess.run([sys.executable,str(root/'scripts/test-native-reference-batch.py'),'--only','worktree-family',*sys.argv[1:]],cwd=root).returncode)
