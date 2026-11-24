"""Opt-in Google Antigravity command hook. Never write diagnostics to hook stdout."""

import json
import os
from pathlib import Path
import pwd
import socket
import stat
import struct
import sys


def ipc_path():
    home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    return home / "Library/Application Support/AgentDeck/lifecycle/events.sock"


def peer_uid(conn):
    if sys.platform == "darwin":
        import ctypes
        uid, gid = ctypes.c_uint(), ctypes.c_uint()
        if ctypes.CDLL(None).getpeereid(conn.fileno(), ctypes.byref(uid), ctypes.byref(gid)) != 0:
            raise PermissionError("peer credentials unavailable")
        return uid.value
    if sys.platform.startswith("linux"):
        creds = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        return struct.unpack("3i", creds)[1]
    raise PermissionError("unsupported peer credentials")


def private_directory(path):
    info = path.lstat()
    return (stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
            and stat.S_IMODE(info.st_mode) == 0o700)


def deliver(msg):
    path = ipc_path()
    if not private_directory(path.parent):
        return
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(1)
        conn.connect(str(path))
        if peer_uid(conn) == os.getuid():
            conn.sendall(json.dumps(msg).encode() + b"\n")


def listen(on_event, shutdown):
    path = ipc_path()
    path.parent.mkdir(mode=0o700, exist_ok=True)
    if not private_directory(path.parent):
        return
    # Only the daemon holding AgentDeck's singleton HTTP bind starts this listener.
    try:
        old = path.lstat()
        if not stat.S_ISSOCK(old.st_mode) or old.st_uid != os.getuid():
            return
        path.unlink()
    except FileNotFoundError:
        pass
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(str(path))
        server.listen(32)
        server.settimeout(0.5)
        while not shutdown.is_set():
            try:
                conn, _ = server.accept()
            except socket.timeout:
                continue
            with conn:
                try:
                    if peer_uid(conn) != os.getuid():
                        continue
                    conn.settimeout(1)
                    with conn.makefile("rb") as stream:
                        line = stream.readline(32769)
                    if len(line) <= 32768 and line.endswith(b"\n"):
                        msg = json.loads(line)
                        if isinstance(msg, dict) and msg.get("type") == "antigravity-lifecycle":
                            on_event(msg)
                except (OSError, ValueError, RecursionError):
                    continue


def envelope(event, data):
    if (event not in ("PreInvocation", "Stop") or not isinstance(data, dict)
            or data.get("hookEventName", event) != event):
        return None
    paths = data.get("workspacePaths")
    cwd = data.get("cwd")
    if not (isinstance(cwd, str) and os.path.isabs(cwd)):
        cwd = paths[0] if isinstance(paths, list) and len(paths) == 1 else ""
    msg = dict(type="antigravity-lifecycle", event=event,
               conversationId=data.get("conversationId"), cwd=cwd)
    sid = msg["conversationId"]
    if isinstance(sid, str):
        for account, directory in (("app", "antigravity"), ("cli", "antigravity-cli"),
                                   ("ide", "antigravity-ide")):
            suffix = f".gemini/{directory}/brain/{sid}"
            if data.get("artifactDirectoryPath") in (f"~/{suffix}", str(Path.home() / suffix)):
                msg["account"] = account
                break
    if event == "Stop":
        msg.update(fullyIdle=data.get("fullyIdle"), terminationReason=data.get("terminationReason"),
                   hasError=data.get("error", "") != "")
    return msg


def main(event):
    try:
        raw = sys.stdin.buffer.read(1048577)
        msg = envelope(event, json.loads(raw)) if len(raw) <= 1048576 else None
        if msg:
            deliver(msg)
    except (ValueError, RecursionError, OSError):
        pass
    finally:
        print('{"decision":"allow"}' if event == "Stop" else "{}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) == 2 else "")
