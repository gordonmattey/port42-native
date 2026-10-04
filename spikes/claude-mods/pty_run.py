"""Run interactive claude with the probe mod in a pty and let the mod's timer submit a prompt (spike #255)."""
import os, pty, select, time, signal, sys, struct, fcntl, termios

cwd = "/tmp/mods-spike/cwd"
pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd)
    if os.environ.get("P42_CFG"): os.environ["CLAUDE_CONFIG_DIR"] = os.environ["P42_CFG"]
    if os.environ.get("P42_NOKEY"): os.environ.pop("ANTHROPIC_API_KEY", None)
    for k in list(os.environ):
        if k.startswith("CLAUDE_CODE_") or k in ("CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT"):
            os.environ.pop(k, None)   # session markers inherited from the launching Claude; the shim's sanitizeEnv drops three of them
    os.execvp("claude", ["claude"] + (["--bare"] if os.environ.get("P42_BARE") else []) + (["--permission-mode", os.environ["P42_PERM"]] if os.environ.get("P42_PERM") else []) + ["--plugin-dir", "/tmp/mods-spike/p42-mod"] + ([] if os.environ.get("P42_DEFAULT_SETTINGS") else ["--setting-sources", ""]))
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))
start = time.time()
buf = b""
sent_enter = 0
typed = False
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
    if os.environ.get('P42_ENTERS') and sent_enter < int(os.environ['P42_ENTERS']) and t > 3 + sent_enter * 2:
        os.write(fd, os.environ.get('P42_KEY','\r').encode().decode('unicode_escape').encode())
        sent_enter += 1
    if os.environ.get('P42_TYPE') and not typed and t > 8:
        os.write(fd, os.environ['P42_TYPE'].encode()); time.sleep(0.5); os.write(fd, b"\r"); typed = True
open("/tmp/mods-spike/pty.out", "wb").write(buf)
try:
    os.write(fd, b"\x03\x03")
    time.sleep(1)
    os.kill(pid, signal.SIGTERM)
except Exception:
    pass
print("captured", len(buf), "bytes of terminal output")
