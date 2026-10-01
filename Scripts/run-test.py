"""Bound sanitizer-runtime failures without changing OS security or toolchains."""
import pathlib
import subprocess
import sys

binary, log_path = sys.argv[1:]
try:
    result = subprocess.run([binary], capture_output=True, text=True, timeout=30)
    output = result.stdout + result.stderr
    status = result.returncode
    output += f"TEST_PROCESS_EXIT_STATUS: {status}\n"
except subprocess.TimeoutExpired as error:
    output = (error.stdout or b"").decode() + (error.stderr or b"").decode()
    output += "TIMEOUT: test executable did not finish within 30 seconds. This is NOT a passing test.\n"
    status = 124
pathlib.Path(log_path).write_text(output)
print(output, end="")
sys.exit(status)
