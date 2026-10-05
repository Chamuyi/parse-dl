"""撞名实测：同目录同名文件已存在时，aria2 到底是覆盖、改名另存，还是报错。

严格复刻应用的调用方式：只传 dir + out，**不带** --allow-overwrite /
--auto-file-renaming（见 lib/services/aria2.dart 的启动参数与 addUri options）。
两轮：同一进程内重复入队、重启进程后再入队一次。

在项目根目录跑：python tool/aria2_nameclash_probe.py
只写临时目录，不碰任何真实下载目录。
"""
import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from aria2_pause_probe import (ARIA2, TOTAL, Server, free_port, rpc,  # noqa: E402
                               start)

NAME = 'clip.jpeg'
# 预置哪一种同名原件：short = 半截/别的文件；full = 尺寸正好等于远端
MODE = sys.argv[1] if len(sys.argv) > 1 else 'short'
ORIGINAL = b'O' * TOTAL if MODE == 'full' else (
    b'ORIGINAL-USER-FILE-DO-NOT-TOUCH' + b'.' * 8)


def listing(dl, tag):
    print(f'  [{tag}] 目录内容：')
    for f in sorted(os.listdir(dl)):
        p = os.path.join(dl, f)
        if not os.path.isfile(p):
            print(f'      <dir> {f}')
            continue
        size = os.path.getsize(p)
        head = open(p, 'rb').read(40)
        mark = '原件内容' if head.startswith(ORIGINAL[:20]) else ('aria2 下载内容' if head[:1] in (b'x',) else '其他')
        print(f'      {f:24} {size:>12,}  {mark}')


def wait(port, gid, limit=90):
    t0 = time.time()
    while time.time() - t0 < limit:
        d = rpc(port, 'aria2.tellStatus', [gid])
        s = d.get('status')
        if s in ('complete', 'error', 'removed', 'paused'):
            return s, (d.get('errorMessage') or '')
        time.sleep(1.0)
    return 'timeout', ''


def main():
    if not os.path.exists(ARIA2):
        print('找不到 assets/aria2c.exe，请在项目根目录跑')
        sys.exit(1)
    tmp = tempfile.mkdtemp(prefix='aria2clash-')
    dl = os.path.join(tmp, 'dl')
    os.makedirs(dl)
    session = os.path.join(tmp, 'aria2.session')
    # 预先放一个「你已经下载好、正打算移走」的同名原件
    with open(os.path.join(dl, NAME), 'wb') as f:
        f.write(ORIGINAL)
    print('预置同名原件：dl/%s = %d 字节  模式=%s（首字节 %r）' % (
        NAME, len(ORIGINAL), MODE, ORIGINAL[:1]))

    try:
        with Server() as srv:
            url = f'http://127.0.0.1:{srv.port}/{NAME}'
            port = free_port()
            proc = start(port, dl, session, resume=False)
            time.sleep(2.0)
            print('=== 第一轮：同一 aria2 进程内，对同名文件再次入队 ===')
            gid = rpc(port, 'aria2.addUri', [[url], {'dir': dl, 'out': NAME}])
            st, err = wait(port, gid)
            print(f'  结果 status={st} {("err=" + err) if err else ""}')
            listing(dl, '第一轮后')
            proc.terminate()
            proc.wait(timeout=15)

            print('=== 第二轮：重启 aria2（模拟下次启动程序）再入队同名 ===')
            for f in os.listdir(dl):
                if f.endswith('.aria2'):
                    os.remove(os.path.join(dl, f))
            port2 = free_port()
            proc2 = start(port2, dl, os.path.join(tmp, 'aria2.session2'), resume=False)
            time.sleep(2.0)
            gid2 = rpc(port2, 'aria2.addUri', [[url], {'dir': dl, 'out': NAME}])
            st2, err2 = wait(port2, gid2)
            print(f'  结果 status={st2} {("err=" + err2) if err2 else ""}')
            listing(dl, '第二轮后')
            print('  原件是否还在：', os.path.exists(os.path.join(dl, NAME)))
            proc2.terminate()
            proc2.wait(timeout=15)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    main()
