"""Run interactive claude with the probe mod in a pty and let the mod's timer submit a prompt (spike #255)."""
import os, pty, select, time, signal, sys, struct, fcntl, termios

cwd = "/tmp/mods-spike/cwd"
pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd)
    for k in ("CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_BRIDGE_SESSION_ID"):
        os.environ.pop(k, None)   # what port42-claude-shim's sanitizeEnv drops, for the same reason
    os.execvp("claude", ["claude", "--plugin-dir", "/tmp/mods-spike/p42-mod", "--setting-sources", ""])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))
start = time.time()
buf = b""
sent_enter = 0
while time.time() - start < float(sys.argv[1] if len(sys.argv) > 1 else 45):
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        try:
            d = os.read(fd, 65536)
        except OSError:
            break
        if not d:
            break
        buf += d
    t = time.time() - start
    # a first-run trust or theme dialog may be waiting: press Enter twice, early
    if sent_enter < 2 and t > 2.5 + sent_enter * 2:
        os.write(fd, b"\r")
        sent_enter += 1
open("/tmp/mods-spike/pty.out", "wb").write(buf)
try:
    os.write(fd, b"\x03\x03")
    time.sleep(1)
    os.kill(pid, signal.SIGTERM)
except Exception:
    pass
print("captured", len(buf), "bytes of terminal output")
