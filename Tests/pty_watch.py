#!/usr/bin/env python3
"""Real controlling-terminal regression for one Ctrl-C through refik watch."""
import errno
import os
import pty
import select
import signal
import sys
import time
import tempfile

cli = sys.argv[1]
child_program = (
    "import signal,sys,time\n"
    "def stop(number, frame):\n"
    " print('SIGNAL_ONCE', flush=True)\n"
    " sys.exit(130)\n"
    "signal.signal(signal.SIGINT, stop)\n"
    "print('\\x1b[31mREADY\\x1b[0m', flush=True)\n"
    "line=sys.stdin.readline()\n"
    "print('ECHO:'+line.strip(), flush=True)\n"
    "while True: time.sleep(1)\n"
)
isolated_store = tempfile.TemporaryDirectory(prefix="refik-pty-")
pid, master = pty.fork()
if pid == 0:
    os.environ["REFIK_DATA_DIR"] = isolated_store.name
    os.execv(cli, [cli, "watch", sys.executable, "-c", child_program])

captured = bytearray()

def read_until(marker, deadline):
    while marker not in captured:
        if time.monotonic() >= deadline:
            raise AssertionError(f"timeout waiting for {marker!r}: {captured[-500:]!r}")
        ready, _, _ = select.select([master], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(master, 4096)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            captured.extend(chunk)

try:
    read_until(b"READY", time.monotonic() + 10)
    os.write(master, b"input with spaces\n")
    read_until(b"ECHO:input with spaces", time.monotonic() + 10)
    os.write(master, b"\x03")
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(master, 4096)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            captured.extend(chunk)
        exited, status = os.waitpid(pid, os.WNOHANG)
        if exited:
            break
    else:
        os.kill(pid, signal.SIGKILL)
        raise AssertionError("watch did not exit after Ctrl-C")
    if not exited:
        exited, status = os.waitpid(pid, 0)
    assert os.WIFEXITED(status), status
    assert os.WEXITSTATUS(status) == 130, (status, captured[-500:])
    assert captured.count(b"SIGNAL_ONCE") == 1, captured[-500:]
    assert b"\x1b[31mREADY\x1b[0m" in captured, captured[-500:]
    assert b"ECHO:input with spaces" in captured, captured[-500:]
    print("PTY Ctrl-C: one child SIGINT, exit 130, stdin and ANSI preserved")
finally:
    os.close(master)
    isolated_store.cleanup()
