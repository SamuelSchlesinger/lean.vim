#!/usr/bin/env python3
"""Run a headless Vim script with EOF and a bounded process lifetime."""

import os
import signal
import subprocess
import sys
from pathlib import Path

environment = dict(os.environ, LEAN_VIM_TEST_SCRIPT=str(Path(sys.argv[1]).resolve()))
vim = os.environ.get("LEAN_VIM_TEST_VIM", "vim")
timeout = float(os.environ.get("LEAN_VIM_TEST_TIMEOUT", "120"))

with subprocess.Popen(
    [vim, "-Nu", "NONE", "-i", "NONE", "-n", "-es", "-V1", "-S",
     str(Path(__file__).with_suffix(".vim"))],
    env=environment,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    start_new_session=os.name == "posix",
) as process:
    try:
        output, _ = process.communicate(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        # Stop the test's process group, including subprocesses which inherit
        # its output pipes, so collecting output cannot extend the timeout.
        try:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
        except ProcessLookupError:
            pass  # The test exited between the timeout and the kill.
        output, _ = process.communicate()
        sys.stdout.buffer.write(output)
        if isinstance(error, subprocess.TimeoutExpired):
            sys.stderr.write(f"\n{sys.argv[1]} exceeded its {timeout:g}-second timeout\n")
            sys.exit(1)
        sys.exit(130)

if process.returncode:
    sys.stdout.buffer.write(output)
else:
    print(f"PASS {sys.argv[1]}")
sys.exit(process.returncode)
