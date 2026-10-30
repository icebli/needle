#!/usr/bin/env python3
"""Replace only an installed Needle queue listener after installing its new binary."""
import ctypes
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import urlopen

ADDRESS = "http://127.0.0.1:29878/queue?protocol=2"


def executable_path(pid):
    if sys.platform == "darwin":
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        buffer = ctypes.create_string_buffer(4096)
        length = library.proc_pidpath(pid, buffer, len(buffer))
        return buffer.value.decode() if length > 0 else None
    try:
        return os.readlink(f"/proc/{pid}/exe")
    except OSError:
        return None


def listener_pids():
    result = subprocess.run(["lsof", "-nP", "-t", "-iTCP@127.0.0.1:29878", "-sTCP:LISTEN"], capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise RuntimeError("Could not inspect the Spotify queue listener; installation cannot verify its upgrade.")
    return sorted({int(value) for value in result.stdout.split()})


def identity(pid, allowed):
    path = executable_path(pid)
    if path not in allowed:
        raise RuntimeError(f"Port 29878 belongs to an unrecognized executable for PID {pid}; it was left running.")
    result = subprocess.run(["ps", "-p", str(pid), "-o", "uid=", "-o", "lstart=", "-o", "command="], check=True, capture_output=True, text=True)
    record = result.stdout.strip()
    fields = record.split(None, 6)
    if len(fields) != 7 or int(fields[0]) != os.getuid() or fields[6] != f"{path} serve":
        raise RuntimeError(f"PID {pid} is not this user's exact Needle serve process; it was left running.")
    return path, record


def protocol_ready():
    try:
        with urlopen(ADDRESS, timeout=0.5) as response:
            return response.status == 200 and isinstance(json.load(response), list)
    except (OSError, URLError, ValueError):
        return False


def restart(host, allowed):
    listeners = listener_pids()
    verified = [(pid, identity(pid, allowed)) for pid in listeners]
    for pid, expected in verified:
        if identity(pid, allowed) != expected:
            raise RuntimeError(f"Needle listener PID {pid} changed during installation; it was left running.")
        os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 5
    while listener_pids():
        if time.monotonic() >= deadline:
            raise RuntimeError("The old Needle queue listener did not stop. The queue was preserved.")
        time.sleep(0.1)
    with open(os.devnull, "wb") as null:
        process = subprocess.Popen([host, "serve"], stdin=subprocess.DEVNULL, stdout=null, stderr=null, start_new_session=True)
    deadline = time.monotonic() + 5
    while True:
        if process.poll() is not None or time.monotonic() >= deadline:
            raise RuntimeError("The installed Needle host did not confirm the current queue protocol. The queue was preserved.")
        if protocol_ready():
            if listener_pids() != [process.pid]:
                raise RuntimeError("The queue listener changed while starting Needle. The queue was preserved.")
            identity(process.pid, {host})
            if process.poll() is not None:
                raise RuntimeError("The installed Needle listener exited during verification. The queue was preserved.")
            break
        time.sleep(0.1)
    print("Spotify queue host upgraded; pending jobs and receipts preserved.")


if __name__ == "__main__":
    installed = str(Path(sys.argv[1]).absolute())
    try:
        restart(installed, set(sys.argv[1:]))
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
