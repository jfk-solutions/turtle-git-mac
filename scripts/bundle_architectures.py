"""Audit distributor-owned code slices without executing app binaries."""
from pathlib import Path
import subprocess

APPLICATION_CODE = (
    "Contents/MacOS/TurtleGitMac",
    "Contents/MacOS/TurtleGitWCRev",
    "Contents/Frameworks/TurtleGitCore.framework/TurtleGitCore",
    "Contents/Frameworks/TurtleGitSMTP.framework/TurtleGitSMTP",
    "Contents/PlugIns/TurtleGitFinder.appex/Contents/MacOS/TurtleGitFinder",
    "Contents/Library/LaunchServices/TurtleGitCache.app/Contents/MacOS/TurtleGitCache",
    "Contents/Helpers/SSHAskpass/TurtleGitSSHAskpass",
    "Contents/Helpers/GitAskpass/TurtleGitGitAskpass",
)

def audit_application_architectures(app, required=("arm64", "x86_64")):
    root = Path(app).resolve(strict=True)
    result = {}
    for relative in APPLICATION_CODE:
        path = (root / relative).resolve(strict=True)
        if not path.is_relative_to(root) or not path.is_file():
            raise ValueError("Application code escapes the bundle: " + relative)
        slices = subprocess.check_output(["/usr/bin/lipo", "-archs", str(path)], text=True).split()
        if not set(required).issubset(slices):
            raise ValueError(relative + " requires " + ", ".join(required) + "; found " + ", ".join(slices))
        result[relative] = slices
    return result
