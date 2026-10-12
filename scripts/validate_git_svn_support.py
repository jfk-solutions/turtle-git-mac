"""Share the existing per-slice deployment reader without running its CLI."""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location('turtlegit_git_runtime_validation', Path(__file__).with_name('validate-git-runtime.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
deployment = module.audit_deployment
