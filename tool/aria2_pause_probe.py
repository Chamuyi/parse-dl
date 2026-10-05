"""实测 aria2 的暂停/继续语义，判断「点暂停后无法继续」出在哪一层。

不碰应用、不碰任何登录态：用随包的 assets/aria2c.exe + 本机 HTTP 服务。

服务器必须正确支持 Range —— aria2 暂停后会带着 Range 重连，第一版探针用了个
不支持 Range、且一被掐断连接就抛异常的简陋 handler，结果 unpause 之后测出来
是 `error`，那是脚手架的锅不是 aria2 的语义。这版把连接被掐当正常现象吞掉。

用法（在项目根目录）：python tool/aria2_pause_probe.py
"""
import http.server
import json
import os
import re
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

ARIA2 = os.path.abspath('assets/aria2c.exe')
SECRET = 'probe-secret'
TOTAL = 40 << 20          # 40 MB，慢到足以中途暂停
CHUNK = 1 << 20


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


class RangeHandler(http.server.BaseHTTPRequestHandler):
    """支持 Range 的静态文件；连接被客户端掐断是正常事，静默收尾。"""
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def _serve(self, head_only=False):
        m = re.match(r'bytes=(\d*)-(\d*)', self.headers.get('Range') or '')
        start = int(m.group(1)) if m and m.group(1) else 0
        end = int(m.group(2)) if m and m.group(2) else TOTAL - 1
        end = min(end, TOTAL - 1)
        length = max(0, end - start + 1)
        self.send_response(206 if m else 200)
        self.send_header('Content-Length', str(length))
        if m:
            self.send_header('Content-Range', f'bytes {start}-{end}/{TOTAL}')
        self.send_header('Accept-Ranges', 'bytes')
        self.end_headers()
        if head_only:
            return
        left = length
        try:
            while left > 0:
                n = min(left, CHUNK)
                self.wfile.write(b'x' * n)
                left -= n
                time.sleep(0.10)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def do_GET(self):
        self._serve()

    def do_HEAD(self):
        self._serve(head_only=True)


class Server:
    def __enter__(self):
        self.port = free_port()
        httpd = socketserver.ThreadingTCPServer(('127.0.0.1', self.port),
                                                RangeHandler)
        httpd.daemon_threads = True
        self.httpd = httpd
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *a):
        self.httpd.shutdown()
        self.httpd.server_close()


def rpc(port, method, params):
    body = json.dumps({
        'jsonrpc': '2.0',
        'id': 'p',
        'method': method,
        'params': ['token:' + SECRET] + params,
    }).encode()
    req = urllib.request.Request(f'http://127.0.0.1:{port}/jsonrpc',
                                 data=body,
                                 headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        raise RuntimeError(
            f'{method} HTTP {e.code}: {e.read()[:200]!r}') from None
    out = json.loads(raw)
    if 'error' in out:
        raise RuntimeError(f'{method} -> {out["error"]}')
    res = out['result']
    return res[0] if isinstance(res, list) and len(res) == 1 else res


def st(port, gid):
    try:
        d = rpc(port, 'aria2.tellStatus', [gid])
        err = d.get('errorMessage') or ''
        return f"{d.get('status')}{(' / ' + err) if err else ''}"
    except Exception as e:
        return f'查不到（{e}）'


def start(port, dl, session, resume):
    args = [
        ARIA2, '--enable-rpc', f'--rpc-secret={SECRET}',
        f'--rpc-listen-port={port}', '--continue=true',
        f'--save-session={session}', '--save-session-interval=1',
        '--auto-save-interval=1', f'--dir={dl}',
        '--max-concurrent-downloads=4', '--summary-interval=0',
        '--console-log-level=warn',
    ]
    if resume and os.path.exists(session):
        args.append(f'--input-file={session}')
    return subprocess.Popen(args, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)


def main():
    if not os.path.exists(ARIA2):
        print('找不到 assets/aria2c.exe，请在项目根目录跑')
        sys.exit(1)
    tmp = tempfile.mkdtemp(prefix='aria2probe-')
    dl = os.path.join(tmp, 'dl')
    os.makedirs(dl)
    session = os.path.join(tmp, 'aria2.session')
    with Server() as srv:
        url = f'http://127.0.0.1:{srv.port}/big.bin'
        port = free_port()
        proc = start(port, dl, session, resume=False)
        time.sleep(2.0)
        print('=== 第一轮：同一次 aria2 运行内 暂停 → 继续 ===')
        gid = rpc(port, 'aria2.addUri', [[url]])
        time.sleep(1.2)
        print(f'  下载中        : {st(port, gid)}')
        rpc(port, 'aria2.pause', [gid])
        print(f'  pause 之后    : {st(port, gid)}')
        try:
            rpc(port, 'aria2.unpause', [gid])
        except Exception as e:
            print(f'  unpause 失败  : {e}')
        time.sleep(2.5)
        print(f'  unpause 两秒后: {st(port, gid)}   <-- 同进程内能不能续上')

        try:
            rpc(port, 'aria2.pause', [gid])
            print('  再次 pause 成功')
        except Exception as e:
            print(f'  再次 pause 失败: {e}')
        time.sleep(2.5)
        blob = ''
        if os.path.exists(session):
            blob = open(session, encoding='utf-8', errors='replace').read()
        print(f'  会话文件里有这个 gid : {gid in blob}'
              f'（{blob.count(chr(10))} 行）  <-- aria2 存不存 paused 任务')
        proc.terminate()
        proc.wait(timeout=10)
        time.sleep(0.5)

        print('=== 第二轮：带 --input-file 重启后 ===')
        port_b = free_port()
        proc_b = start(port_b, dl, session, resume=True)
        time.sleep(2.5)
        try:
            a = rpc(port_b, 'aria2.tellActive', [])
            w = rpc(port_b, 'aria2.tellWaiting', [0, 50])
            sp = rpc(port_b, 'aria2.tellStopped', [0, 50])
            print(f'  active={len(a)} waiting={len(w)} stopped={len(sp)}')
        except Exception as e:
            print(f'  列表查询失败: {e}')
        print(f'  旧 gid 状态   : {st(port_b, gid)}')
        try:
            rpc(port_b, 'aria2.unpause', [gid])
            print(f'  重启后 unpause 成功 -> {st(port_b, gid)}')
        except Exception as e:
            print(f'  重启后 unpause 失败 : {e}'
                  '   <-- 界面上「继续」点了没反应就是这条')
        proc_b.terminate()
        proc_b.wait(timeout=10)
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    main()
