"""对照实验：服务器**不支持 Range/续传**时，同名文件已存在，aria2 是覆盖还是改名另存。

另一个探针（aria2_nameclash_probe.py）用的本地服务器专门支持 Range（为了
测暂停/继续才这么写），结果实测是「覆盖」；可磁盘上真实存在 5000+ 个 `.1/.2`
改名件 —— 两者矛盾，怀疑差异就出在「远端能不能续传」。

这一版把服务器换成只会回 200 全量、忽略 Range 的形态，其余参数与应用一致
（--continue=true，只传 dir/out，不设 allow-overwrite / auto-file-renaming）。

在项目根目录跑：python tool/aria2_norange_clash_probe.py
"""
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import http.server

ARIA2 = os.path.abspath('assets/aria2c.exe')
SECRET = 'probe-secret'
NAME = 'clip.jpg'
TOTAL = 1 << 20          # 1 MB，快
ORIGINAL = b'ORIGINAL-USER-FILE' + b'.' * 14


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


class NoRangeHandler(http.server.BaseHTTPRequestHandler):
    """永远 200 全量，忽略 Range —— 对应「不支持断点续传」的远端。"""
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def do_HEAD(self):
        self.send_response(200)
        self.send_header('Content-Length', str(TOTAL))
        self.end_headers()

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', str(TOTAL))
        # 刻意不送 Accept-Ranges：客户端没法续传
        self.end_headers()
        left = TOTAL
        try:
            while left > 0:
                n = min(left, 64 << 10)
                self.wfile.write(b'x' * n)
                left -= n
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


def rpc(port, method, params):
    import json
    import urllib.request
    body = json.dumps({
        'jsonrpc': '2.0',
        'id': 'p',
        'method': method,
        'params': ['token:' + SECRET] + params,
    }).encode()
    req = urllib.request.Request(f'http://127.0.0.1:{port}/jsonrpc',
                                 data=body,
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=15) as r:
        out = json.loads(r.read())
    if 'error' in out:
        raise RuntimeError(f'{method} -> {out["error"]}')
    res = out['result']
    return res[0] if isinstance(res, list) and len(res) == 1 else res


def listing(dl, tag):
    print(f'  [{tag}] 目录内容：')
    for f in sorted(os.listdir(dl)):
        p = os.path.join(dl, f)
        if not os.path.isfile(p):
            continue
        head = open(p, 'rb').read(18)
        kind = '原件内容' if head == ORIGINAL[:18] else ('新下载' if head[:1] == b'x' else '混合/其他')
        print(f'      {f:34} {os.path.getsize(p):>12,}  {kind}')


def main():
    if not os.path.exists(ARIA2):
        print('找不到 assets/aria2c.exe，请在项目根目录跑')
        sys.exit(1)
    tmp = tempfile.mkdtemp(prefix='aria2norange-')
    dl = os.path.join(tmp, 'dl')
    os.makedirs(dl)
    with open(os.path.join(dl, NAME), 'wb') as f:
        f.write(ORIGINAL)
    print('预置同名原件 %s = %d 字节（内容 ORIGINAL…）' % (NAME, len(ORIGINAL)))

    srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), NoRangeHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port_http = srv.server_address[1]
    url = f'http://127.0.0.1:{port_http}/{NAME}'

    rpc_port = free_port()
    args = [
        ARIA2, '--enable-rpc', f'--rpc-secret={SECRET}',
        f'--rpc-listen-port={rpc_port}', '--continue=true',
        f'--dir={dl}', '--max-concurrent-downloads=4',
        '--summary-interval=0', '--console-log-level=warn',
    ]
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        import time
        time.sleep(2.0)
        print('aria2 版本 =', rpc(rpc_port, 'aria2.getVersion', [])['version'])
        gid = rpc(rpc_port, 'aria2.addUri', [[url], {'dir': dl, 'out': NAME}])
        for _ in range(60):
            d = rpc(rpc_port, 'aria2.tellStatus', [gid])
            if d.get('status') in ('complete', 'error', 'removed'):
                print('  status=%s %s' % (d['status'], d.get('errorMessage') or ''))
                break
            time.sleep(0.5)
        listing(dl, '不支持续传的远端、同名文件已存在')
    finally:
        proc.terminate()
        proc.wait(timeout=15)
        srv.shutdown()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    main()
