#!/usr/bin/env python3
"""Bounded archive validator; never executes workspace code."""
import sys
import tempfile
from pathlib import Path
from workspace import MAX_BYTES, unpack, pack
try:
    action, source = sys.argv[1:3]
    if action == 'validate':
        with open(source,'rb') as f:
            data=f.read(MAX_BYTES+1)
        with tempfile.TemporaryDirectory(prefix='pool-validate-') as folder:
            unpack(data, folder)
    elif action == 'pack':
        Path(sys.argv[3]).write_bytes(pack(source))
    elif action == 'unpack':
        with open(source,'rb') as f:
            unpack(f.read(MAX_BYTES+1), sys.argv[3])
    else:
        raise ValueError('Unknown action')
except Exception:
    print('Invalid workspace archive', file=sys.stderr)
    sys.exit(1)
