import socket,os,subprocess,time,threading,json,statistics,sys
SHIM=os.path.expanduser("~/port42-build-architect-boot/Port42Dev9.app/Contents/MacOS/port42-claude-shim")
SOCK="/tmp/mods-spike/h.sock"
try: os.unlink(SOCK)
except FileNotFoundError: pass
srv=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); srv.bind(SOCK); srv.listen(256)
got=[]
def serve():
    while True:
        c,_=srv.accept()
        def h(c):
            data=b""
            while True:
                b=c.recv(65536)
                if not b: break
                data+=b
            got.append(len(data)); c.close()
        threading.Thread(target=h,args=(c,),daemon=True).start()
threading.Thread(target=serve,daemon=True).start()
payload=json.dumps({"hook_event_name":"PreToolUse","session_id":"abc","tool_name":"Bash","tool_input":{"command":"ls -la"}}).encode()
env=dict(os.environ,PORT42_HOOKS_SOCKET=SOCK)
def one():
    t=time.perf_counter()
    subprocess.run([SHIM,"notify","toolStarting","claude"],input=payload,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    return (time.perf_counter()-t)*1000
for _ in range(5): one()
seq=[one() for _ in range(200)]
seq.sort()
print("sequential, 200 runs: p50 %.1f ms, p95 %.1f ms, max %.1f ms"%(seq[100],seq[190],seq[-1]))
def burst(n):
    out=[]
    ths=[threading.Thread(target=lambda:out.append(one())) for _ in range(n)]
    t=time.perf_counter()
    [x.start() for x in ths]; [x.join() for x in ths]
    return (time.perf_counter()-t)*1000, sorted(out)
for n in (10,40):
    tot,o=burst(n)
    print(f"burst of {n} at once: wall {tot:.0f} ms, per-run p50 {o[len(o)//2]:.0f} ms, max {o[-1]:.0f} ms")
time.sleep(0.5); print("events received by the listener:",len(got))
