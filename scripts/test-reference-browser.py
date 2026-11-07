#!/usr/bin/env python3
"""Native reference Browser/Reset handoffs and actual sheet-delivery ownership.

Keep the hosted entry point while sharing the grouped receiver's compilation,
private environment and native window/process cleanup. Existing --git arguments
retain their order and are passed to both complete cases.
"""
import runpy
import sys
from pathlib import Path

if __name__ == '__main__':
    sys.argv = [str(Path(__file__).with_name('test-reference-child-delivery.py')),
                *sys.argv[1:], '--only', 'sheets', '--only', 'browser']
    runpy.run_path(sys.argv[0], run_name='__main__')
