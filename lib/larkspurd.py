#!/usr/bin/env python3
"""Larkspur 常驻服务（larkspurd）：把不需要 Claude 的部分从总控会话里拆出来，不依赖 Claude 桌面端。

它负责：
  1. 飞书监听：有活动的总控记录时，运行 listen.sh <总控私聊> --hub（私聊消息、卡片、菜单、群消息转发），
     到时（29 分钟）或意外退出后自动重启；输出的每一行事件追加到 run/hub-queue，总控会话的钩子
     在后台运行 listen-wait.sh 读取，有事件才唤醒总控。桌面端或总控会话停着时事件不会丢，排在队列里等总控回来。
     总控停着而队列里有事件时，用 hub-revive.sh 打开桌面端里的总控会话把它拉起来（桌面端在运行时才做）。
  2. 每分钟网络检测、刷新飞书控制台、跑 IP 守卫（netwatch.sh）。
  3. 本地网页控制台：只监听 127.0.0.1，端口第一次启动时在 20000～60999 里随机挑一个并记进 config.sh
     （LARKSPUR_WEB_PORT），之后固定不变；被占用时重新随机挑。
     网页上可以看状态、网络检测、开关 IP 闸门、关闭会话同步，以及关闭 Larkspur 本身。

用法：larkspurd.py            前台运行（systemd 用户服务或 larkspurctl.sh 调用）
同时只运行一个（run/daemon.lock）。实际端口等信息写在 run/daemon.json。
收到 SIGTERM、或网页上点「关闭 Larkspur」时，结束所有子进程后以 0 退出（systemd 不会再拉起）。
"""
import fcntl
import json
import random
import os
import re
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

H = os.environ.get("LARKSPUR_HOME") or os.path.expanduser("~/.claude/larkspur")
RUN = os.path.join(H, "run")
QUEUE = os.path.join(RUN, "hub-queue")
INFO = os.path.join(RUN, "daemon.json")
LOG = os.path.join(H, "larkspur.log")
WEB = os.path.join(H, "web")
os.makedirs(RUN, exist_ok=True)

STOP = threading.Event()
STARTED = time.time()


def log(msg):
    try:
        with open(LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except OSError:
        pass


def bash(*args, timeout=60):
    """运行 Larkspur 的脚本，返回 (退出码, stdout, stderr)。"""
    try:
        p = subprocess.run(["bash", *args], capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "超时"


def cfg():
    """读 common.sh 算出来的配置（含 config.sh），每次现读，改了配置不用重启。"""
    keys = ["WEB_PORT", "EXPECTED_IP", "IP_GUARD", "DESKTOP_GATE", "IP_GUARD_CMD", "NET_REFRESH", "OPEN_ID"]
    script = '. "$LARKSPUR_HOME/common.sh" >/dev/null 2>&1; ' + "; ".join(f'printf "%s\\n" "${{{k}:-}}"' for k in keys)
    env = dict(os.environ, LARKSPUR_HOME=H)
    try:
        out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env, timeout=10).stdout
    except subprocess.TimeoutExpired:
        out = ""
    vals = out.split("\n")
    return {k: (vals[i] if i < len(vals) else "") for i, k in enumerate(keys)}


def hub():
    """活动总控的 (chat_id, desktop_id)，没有时返回 (None, None)。"""
    d = os.path.join(H, "sessions")
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return None, None
    for n in names:
        if not n.endswith(".json"):
            continue
        try:
            with open(os.path.join(d, n)) as f:
                s = json.load(f)
        except (OSError, ValueError):
            continue
        if s.get("role") == "hub" and s.get("active") is True and s.get("chat_id"):
            return s["chat_id"], s.get("desktop_id") or "local_" + str(s.get("session_id"))
    return None, None


def hub_reader_state():
    """与 common.sh 的 hub_reader_state 一致：waiting（等待进程在跑）、busy（刚交出事件、总控的 Claude 进程还在）、stopped。"""
    if pid_alive("inbox"):
        return "waiting"
    try:
        parts = open(os.path.join(RUN, "inbox.handoff")).read().split()
        t = int(parts[0])
        pid = int(parts[1]) if len(parts) > 1 else None
    except (OSError, ValueError, IndexError):
        return "stopped"
    if time.time() - t >= int(os.environ.get("LARKSPUR_HANDOFF_GRACE", "3600")):
        return "stopped"
    if pid is not None:
        try:
            os.kill(pid, 0)
        except OSError:
            return "stopped"
    return "busy"


def pid_alive(name):
    """run/<name>.pid 里的进程是否还活着（与 common.sh 的 listener_alive 一致：命令行里要有 listen）。"""
    try:
        pid = int(open(os.path.join(RUN, name + ".pid")).read().strip())
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return b"listen" in f.read()
    except (OSError, ValueError):
        return False


def append_queue(line):
    """追加一行事件给总控；与 listen-wait.sh 共用 flock，读完后它会清空文件。"""
    with open(QUEUE + ".lock", "a") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        with open(QUEUE, "a") as q:
            q.write(line if line.endswith("\n") else line + "\n")
    NEW_EVENT.set()


NEW_EVENT = threading.Event()


def revive_loop():
    """总控停着（例如桌面端重启后总控会话没被打开）而队列里有事件时，用 hub-revive.sh 把总控会话拉起来。
    有新事件时马上试，之后只要还有事件排着就每分钟再看一次（脚本自己限制频率、检查桌面端是否在运行）。"""
    while not STOP.is_set():
        NEW_EVENT.wait(60)
        NEW_EVENT.clear()
        if STOP.is_set():
            break
        if queue_pending() > 0:
            bash(os.path.join(H, "hub-revive.sh"), "event", timeout=30)


class Child:
    """一个在自己进程组里运行的子进程，结束时连同它的整组子孙一起结束。"""

    def __init__(self, name, argv, stdout=subprocess.DEVNULL, env=None):
        self.name, self.argv, self.stdout, self.env, self.p, self.since = name, argv, stdout, env, None, 0.0

    def start(self):
        self.p = subprocess.Popen(self.argv, stdin=subprocess.DEVNULL, stdout=self.stdout,
                                  stderr=subprocess.STDOUT, start_new_session=True, text=True, bufsize=1,
                                  env=self.env)
        self.since = time.time()
        return self.p

    def running(self):
        return self.p is not None and self.p.poll() is None

    def stop(self):
        if not self.running():
            return
        for sig, wait in ((signal.SIGTERM, 3), (signal.SIGKILL, 2)):
            try:
                os.killpg(self.p.pid, sig)
            except ProcessLookupError:
                return
            try:
                self.p.wait(wait)
                return
            except subprocess.TimeoutExpired:
                pass


LISTENER = {"child": None, "chat": None, "restarts": 0, "last_exit": ""}
NETWATCH = Child("netwatch", ["bash", os.path.join(H, "netwatch.sh"), str(os.getpid())])


def listener_loop():
    backoff = 1
    while not STOP.is_set():
        chat, _ = hub()
        if not chat:
            LISTENER.update(child=None, chat=None)
            STOP.wait(5)
            continue
        c = Child("listener", ["bash", os.path.join(H, "listen.sh"), chat, "--hub"], stdout=subprocess.PIPE,
                  env=dict(os.environ, LARKSPUR_DAEMON="1"))   # 标明是服务自己的监听，见 listen.sh
        p = c.start()
        LISTENER.update(child=c, chat=chat)
        log(f"daemon-listener-start chat={chat} pid={p.pid}")

        def pump(stream=p.stdout):
            for line in stream:
                append_queue(line)
        t = threading.Thread(target=pump, daemon=True)
        t.start()
        while not STOP.is_set() and c.running():
            STOP.wait(5)
            if hub()[0] != chat:          # 总控换了或关了
                log(f"daemon-listener-hub-changed chat={chat}")
                break
        c.stop()
        t.join(3)
        if STOP.is_set():
            break
        ran = time.time() - c.since
        LISTENER["restarts"] += 1
        LISTENER["last_exit"] = time.strftime("%H:%M:%S")
        backoff = 1 if ran > 60 else min(backoff * 2, 60)   # 反复秒退时退避，最长 1 分钟
        STOP.wait(backoff)


def netwatch_loop():
    while not STOP.is_set():
        if not NETWATCH.running():
            NETWATCH.start()
        STOP.wait(10)
    NETWATCH.stop()


# ---------------- 网页控制台 ----------------

def state():
    rc, out, _ = bash(os.path.join(H, "console.sh"), "data", timeout=30)
    try:
        d = json.loads(out) if rc == 0 else {}
    except ValueError:
        d = {}
    c = cfg()
    chat, desk = hub()
    lc = LISTENER["child"]
    d["daemon"] = {
        "pid": os.getpid(), "started": int(STARTED), "uptime": int(time.time() - STARTED),
        "port": SERVER_INFO.get("port"), "wanted_port": SERVER_INFO.get("wanted_port"),
        "port_note": SERVER_INFO.get("note", ""),
        "hub_chat": chat, "hub_desktop": desk,
        "listener": bool(lc and lc.running()), "listener_restarts": LISTENER["restarts"],
        "hub_reader": hub_reader_state() != "stopped", "hub_state": hub_reader_state(),
        "queue_pending": queue_pending(),
        "netwatch": NETWATCH.running(),
    }
    d["guardcfg"] = {"expected": c["EXPECTED_IP"], "gate": c["DESKTOP_GATE"] or "on", "guard": c["IP_GUARD"] or "on",
                     "cmd": c["IP_GUARD_CMD"],
                     "gate_installed": _gate_installed()}
    return d


def _gate_installed():
    try:
        return "Claude 桌面端的启动闸门" in open(os.path.expanduser("~/.local/bin/claude-desktop")).read()
    except OSError:
        return False


def queue_pending():
    """队列里还没被总控读走的事件行数（总控读完就清空）。"""
    try:
        with open(QUEUE, "rb") as f:
            return f.read().count(b"\n")
    except OSError:
        return 0


SETTABLE = {"ack", "wait", "backfill", "spawn", "alerts", "prefix", "root", "gate", "guard", "expip"}


class Handler(BaseHTTPRequestHandler):
    server_version = "Larkspur"

    def log_message(self, *a):          # 不记访问日志
        pass

    def _host_ok(self):
        """只认 localhost / 127.0.0.1 / [::1]（防 DNS 重绑定：别的域名解析到 127.0.0.1 也不行）。"""
        host = (self.headers.get("Host") or "").strip().lower()
        name = re.sub(r":\d+$", "", host)
        return name in ("localhost", "127.0.0.1", "[::1]")

    def _origin_ok(self):
        """写操作：必须带自定义头 X-Larkspur（跨站页面没法不经预检就带上，而这里不答预检），
        有 Origin 时必须是本机。这样别的网页没法偷偷让浏览器来关掉软件或改设置。"""
        if self.headers.get("X-Larkspur") != "1":
            return False
        origin = self.headers.get("Origin")
        if origin and not re.match(r"^http://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$", origin):
            return False
        return True

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self._host_ok():
            return self._send(403, {"error": "只能通过 localhost 访问"})
        if self.path in ("/", "/index.html"):
            try:
                return self._send(200, open(os.path.join(WEB, "index.html"), "rb").read(), "text/html; charset=utf-8")
            except OSError:
                return self._send(500, {"error": "缺少网页文件"})
        if self.path == "/api/state":
            return self._send(200, state())
        self._send(404, {"error": "没有这个页面"})

    def do_POST(self):
        if not self._host_ok() or not self._origin_ok():
            return self._send(403, {"error": "拒绝：只接受本机控制台页面发来的请求"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(min(n, 65536)) or b"{}") if n else {}
        except ValueError:
            return self._send(400, {"error": "请求格式不对"})
        if self.path == "/api/netcheck":
            rc, _, err = bash(os.path.join(H, "netcheck.sh"), timeout=60)
            subprocess.Popen(["bash", os.path.join(H, "ipguard.sh"), "--cached"], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            subprocess.Popen(["bash", os.path.join(H, "console.sh"), "refresh"], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            return self._send(200 if rc == 0 else 502, {"ok": rc == 0, "error": err.strip()})
        if self.path == "/api/config":
            key, value = str(body.get("key", "")), str(body.get("value", ""))
            if key not in SETTABLE:
                return self._send(400, {"ok": False, "error": "不能改这一项"})
            rc, _, err = bash(os.path.join(H, "console.sh"), "set", key, value, timeout=20)
            if rc == 0:
                log(f"web-set key={key}")
                subprocess.Popen(["bash", os.path.join(H, "console.sh"), "refresh"], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            return self._send(200 if rc == 0 else 400, {"ok": rc == 0, "error": err.strip()})
        if self.path == "/api/session/off":
            sid = str(body.get("sid", ""))
            if not re.fullmatch(r"[0-9a-fA-F-]{8,64}", sid):
                return self._send(400, {"ok": False, "error": "会话 ID 不对"})
            rc, _, err = bash(os.path.join(H, "off.sh"), sid, "在本地控制台关闭", timeout=30)
            return self._send(200 if rc == 0 else 400, {"ok": rc == 0, "error": err.strip()})
        if self.path == "/api/desktop/start":
            rc, out, err = bash(os.path.join(H, "desktop-start.sh"), "web", timeout=20)
            return self._send(200 if rc == 0 else 409 if rc == 3 else 500,
                              {"ok": rc == 0, "message": out.strip(), "error": (err or out).strip()})
        if self.path == "/api/stop":
            log("daemon-stop-requested source=web")
            self._send(200, {"ok": True})
            threading.Thread(target=shutdown, args=("web",), daemon=True).start()
            return
        self._send(404, {"error": "没有这个接口"})


SERVER_INFO = {}


RANDOM_PORTS = (20000, 60999)   # 随机挑选的高位端口范围（避开常用端口和系统临时端口段）


def serve():
    """端口：LARKSPUR_WEB_PORT 是具体端口就用它；没设（random）时随机挑一个高位端口并写回 config.sh，
    以后一直用它，网址保持不变。记住的端口被别的程序占了，就重新随机挑一个再记下。0 表示由系统临时分配（测试用）。"""
    c = cfg()
    raw = (c["WEB_PORT"] or "random").strip()
    wanted = int(raw) if raw.isdigit() else None
    note = ""

    def bind(port):
        try:
            return ThreadingHTTPServer(("127.0.0.1", port), Handler)
        except OSError as e:
            return e

    httpd = bind(wanted) if wanted is not None else None
    if isinstance(httpd, OSError):
        note = f"原来的端口 {wanted} 用不了（{httpd.strerror}），已改用新的随机端口 {{port}}"
        httpd = None
    if httpd is None:
        rng = random.SystemRandom()
        for _ in range(50):
            h = bind(rng.randint(*RANDOM_PORTS))
            if not isinstance(h, OSError):
                httpd = h
                break
        else:
            log("daemon-web-failed no-port")
            return None
        port = httpd.server_address[1]
        rc, _, err = bash(os.path.join(H, "console.sh"), "set", "webport", str(port), timeout=20)   # 记住，下次还用它
        log(f"daemon-web-port port={port} saved={'yes' if rc == 0 else 'no'}")
    port = httpd.server_address[1]
    SERVER_INFO.update(port=port, wanted_port=wanted, note=note.format(port=port))
    return httpd


def write_info():
    tmp = INFO + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"pid": os.getpid(), "port": SERVER_INFO.get("port"), "wanted_port": SERVER_INFO.get("wanted_port"),
                   "note": SERVER_INFO.get("note", ""), "started": int(STARTED)}, f, ensure_ascii=False)
    os.replace(tmp, INFO)


HTTPD = None


def shutdown(source="signal"):
    if STOP.is_set():
        return
    STOP.set()
    lc = LISTENER["child"]
    if lc:
        lc.stop()
    NETWATCH.stop()
    if HTTPD:
        threading.Thread(target=HTTPD.shutdown, daemon=True).start()
    log(f"daemon-stop source={source}")


def main():
    global HTTPD
    lock = open(os.path.join(RUN, "daemon.lock"), "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        try:
            info = json.load(open(INFO))
            print(f"Larkspur 已在运行：http://localhost:{info.get('port')}/")
        except (OSError, ValueError):
            print("Larkspur 已在运行")
        return 0
    signal.signal(signal.SIGTERM, lambda *_: shutdown("signal"))
    signal.signal(signal.SIGINT, lambda *_: shutdown("signal"))
    HTTPD = serve()
    write_info()
    log(f"daemon-start pid={os.getpid()} port={SERVER_INFO.get('port')}" +
        (f" wanted={SERVER_INFO.get('wanted_port')}" if SERVER_INFO.get("note") else ""))
    threading.Thread(target=listener_loop, daemon=True).start()
    threading.Thread(target=netwatch_loop, daemon=True).start()
    threading.Thread(target=revive_loop, daemon=True).start()
    if HTTPD:
        threading.Thread(target=HTTPD.serve_forever, daemon=True).start()
    while not STOP.is_set():
        STOP.wait(1)
    time.sleep(0.5)          # 让「已关闭」的响应发出去
    if HTTPD:
        HTTPD.server_close()
    try:                     # 端口释放之后才撤掉运行信息，紧接着重启时新实例能用回同一个端口
        os.remove(INFO)
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
