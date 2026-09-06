#!/usr/bin/env python3
"""Run a headless Vim script with EOF and a bounded process lifetime."""

import os
import subprocess
import sys
from pathlib import Path

environment = dict(os.environ, LEAN_VIM_TEST_SCRIPT=str(Path(sys.argv[1]).resolve()))

try:
    result = subprocess.run(
        ["vim", "-Nu", "NONE", "-i", "NONE", "-n", "-es", "-V1", "-S",
         str(Path(__file__).with_suffix(".vim"))],
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=120,
    )
except subprocess.TimeoutExpired as error:
    sys.stdout.buffer.write(error.stdout or b"")
    sys.stderr.write(f"\n{sys.argv[1]} exceeded its 120-second timeout\n")
    sys.exit(1)

if result.returncode:
    sys.stdout.buffer.write(result.stdout)
else:
    print(f"PASS {sys.argv[1]}")
sys.exit(result.returncode)
