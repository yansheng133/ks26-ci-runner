#!/usr/bin/env python3
"""ks26 建置看板 —— 把 watcher 的狀態變成一個可以投影的網頁。

它只讀檔：groups.conf、state/<組>.{sha,tag,src}、watcher.log。
不寫入任何 watcher 的狀態，也不呼叫 watcher，所以隨時可以開關。

進度是真的：watcher 把 `docker build` 的輸出也導進 watcher.log，
BuildKit 會印 `#7 [builder 3/4] RUN go build`，從這裡解析出「第幾步 / 共幾步」。

用法（在 runner 上）：
    ./ks26-board.py                 # 綁 127.0.0.1:8080
    ./ks26-board.py --port 9000
    ./ks26-board.py --bind 0.0.0.0  # 預設不開,這台沒有對外入方向

從筆電看（不需要在 runner 上開任何對外的埠）：
    ssh -i rancher.pem -L 8080:127.0.0.1:8080 ec2-user@<runner>
    然後瀏覽器開 http://127.0.0.1:8080
"""
import argparse, json, os, re, subprocess, sys, time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ANSI = re.compile(r'\x1b\[[0-9;]*m')
# watcher 的 say() 會把色碼一起寫進 log(在終端機跑的時候),先剝掉再比對
TS = re.compile(r'^(\d{2}:\d{2}:\d{2}) (.*)$')
# BuildKit 非 TTY 輸出。兩件事實決定了下面的算法：
#   1. `#8 [builder 4/4] RUN go build` 的 x/y 是「該 stage 內」的編號,不是全域。
#      多階段的 Dockerfile 會有 builder 1..4/4 與 stage-1 1/1,真正的總步數是各 stage 相加。
#   2. 這行是該步「開始」時印的,完成標記是後面的 `#8 DONE 0.1s` 或 `#8 CACHED`
#      (CACHED 不會再印 DONE)。所以進度要數完成標記,不能數開始行,否則一開始就 100%。
STEP = re.compile(r'^#(\d+)\s+\[([^\]]*?)(\d+)/(\d+)\]\s*(.*)$')
STEP_DONE = re.compile(r'^#(\d+)\s+(DONE|CACHED)\b')
# `#10 exporting to image` 是 BuildKit 收尾階段的明確訊號。用它判斷「推送中」,
# 比用「已知步驟都做完了」可靠——後者在下一個 stage 還沒宣告時會誤報。
EXPORTING = re.compile(r'^#\d+\s+exporting to image\b')

MARK_BUILD  = re.compile(r'建置中\s+(\S+)\s+(\S+)')
MARK_OK     = re.compile(r'OK\s+(\S+)\s+→\s+(\S+)')
MARK_FAIL   = re.compile(r'FAIL\s+(\S+)\s+(.*)')
MARK_BLOCK  = re.compile(r'擋下\s+(\S+)\s+——\s+(.*)')
MARK_SKIP   = re.compile(r'略過\s+(\S+)\s+(.*)')
MARK_NOREMOTE = re.compile(r'(\S+)\s+讀不到遠端分支')


def clean(line):
    return ANSI.sub('', line.rstrip('\n'))


def read_conf(path):
    """groups.conf：一行一組 `group1 <repo網址> <分支>`。"""
    groups = []
    if not os.path.isfile(path):
        return groups, False
    with open(path, encoding='utf-8', errors='replace') as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split()
            groups.append({
                'name': parts[0],
                'repo': parts[1] if len(parts) > 1 else '',
                'branch': parts[2] if len(parts) > 2 else 'main',
            })
    return groups, True


def parse_log(path, names, timeout):
    """回傳 {組名: 狀態 dict} 與最後幾行給畫面用。

    一次只會有一組在建(sweep 是循序的),所以「目前建置中」用最後一個
    尚未收尾的 建置中 標記決定;BuildKit 的步驟行沒有組別,歸給它。
    """
    st = {n: {'status': 'waiting', 'step': None, 'step_index': 0, 'step_total': 0,
              'started': None, 'elapsed': None, 'message': None, 'progress': 0.0,
              'steps': {}}
          for n in names}
    tail = []
    if not os.path.isfile(path):
        return st, tail

    with open(path, encoding='utf-8', errors='replace') as fh:
        lines = fh.readlines()[-4000:]

    active = None          # 目前正在建的組名
    day = datetime.now().strftime('%Y-%m-%d')
    for raw in lines:
        line = clean(raw)
        if not line:
            continue
        m = TS.match(line)
        stamp, body = (m.group(1), m.group(2)) if m else (None, line)

        if m:
            tail.append(line)

        mb = MARK_BUILD.search(body)
        if mb and mb.group(1) in st:
            active = mb.group(1)
            g = st[active]
            g.update(status='building', step=None, step_index=0, step_total=0,
                     message=None, progress=0.0, sha_short=mb.group(2))
            g['steps'] = {}
            g['exporting'] = False
            if stamp:
                try:
                    g['started'] = datetime.strptime(day + ' ' + stamp, '%Y-%m-%d %H:%M:%S').timestamp()
                except ValueError:
                    g['started'] = None
            continue

        mo = MARK_OK.search(body)
        if mo and mo.group(1) in st:
            g = st[mo.group(1)]
            g.update(status='done', progress=1.0, step=None, message=None)
            if g.get('started') and stamp:
                try:
                    end = datetime.strptime(day + ' ' + stamp, '%Y-%m-%d %H:%M:%S').timestamp()
                    g['elapsed'] = max(0.0, end - g['started'])
                except ValueError:
                    pass
            if active == mo.group(1):
                active = None
            continue

        mf = MARK_FAIL.search(body)
        if mf and mf.group(1) in st:
            st[mf.group(1)].update(status='failed', message=mf.group(2).strip())
            if active == mf.group(1):
                active = None
            continue

        mk = MARK_BLOCK.search(body)
        if mk and mk.group(1) in st:
            st[mk.group(1)].update(status='blocked', message=mk.group(2).strip(), progress=0.0)
            if active == mk.group(1):
                active = None
            continue

        ms = MARK_SKIP.search(body)
        if ms and ms.group(1) in st:
            st[ms.group(1)].update(status='skipped', progress=1.0)
            continue

        mn = MARK_NOREMOTE.search(body)
        if mn and mn.group(1) in st:
            st[mn.group(1)].update(status='unknown', message='讀不到遠端分支')
            continue

        # BuildKit 的步驟行：沒有組別,歸給目前正在建的那一組
        if active:
            sm = STEP.match(body)
            if sm:
                n = int(sm.group(1))
                st[active]['steps'].setdefault(n, {
                    'stage': sm.group(2).strip() or 'stage',
                    'idx': int(sm.group(3)), 'total': int(sm.group(4)),
                    'desc': '[%s%s/%s] %s' % (sm.group(2), sm.group(3), sm.group(4), sm.group(5)[:60]),
                    'done': False,
                })
                continue
            dm = STEP_DONE.match(body)
            if dm:
                node = st[active]['steps'].get(int(dm.group(1)))
                if node:
                    node['done'] = True
                continue
            if EXPORTING.match(body):
                st[active]['exporting'] = True

    now = time.time()
    for name, g in st.items():
        steps = g.pop('steps', {})
        if steps:
            # 總步數 = 各 stage 的步數相加(builder 4 + stage-1 1 = 5)
            stages = {}
            for node in steps.values():
                stages[node['stage']] = max(stages.get(node['stage'], 0), node['total'])
            g['step_total'] = sum(stages.values())
            g['step_index'] = sum(1 for node in steps.values() if node['done'])
            pending = [n for n, node in sorted(steps.items()) if not node['done']]
            if pending:
                g['step'] = steps[pending[-1]]['desc']
            elif g['status'] == 'building' and g.get('exporting'):
                g['step'] = '封裝映像檔與推送中'
            else:
                # 已印出的步驟剛好都做完,但下一個 stage 還沒開始印——不要誤報成推送中
                g['step'] = steps[max(steps)]['desc']

        if g['status'] == 'building':
            if g.get('started'):
                g['elapsed'] = max(0.0, now - g['started'])
            if g['step_total']:
                # 上限 0.95：還在跑就不該顯示滿格,export／push 也要時間
                g['progress'] = min(0.95, g['step_index'] / g['step_total'])
            elif g['elapsed'] is not None:
                # 還沒印出任何步驟時退回時間估計,不要停在 0% 讓人以為卡住
                g['progress'] = min(0.95, g['elapsed'] / max(1, timeout))
        elif g['status'] == 'done':
            g['step_index'] = g['step_total']
        g.pop('sha_short', None)
        g.pop('exporting', None)
    return st, tail[-14:]


def local_images(engine, registry, image):
    """從容器引擎補上大小與建好時間。引擎不在就安靜跳過。"""
    out = {}
    ref = '%s/%s' % (registry, image)
    try:
        r = subprocess.run(
            [engine, 'images', '--format', '{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}'],
            capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return out
    for line in r.stdout.splitlines():
        parts = line.split('\t')
        if len(parts) != 3:
            continue
        tag, size, created = parts
        # docker images 會省略 docker.io/ 前綴
        if tag.startswith(ref) or tag.startswith(ref.split('/', 1)[1]):
            out[tag.rsplit(':', 1)[-1]] = {'size': size, 'built_at': created[:19]}
    return out


def detect_engine():
    for e in (os.environ.get('KS26_ENGINE'), 'docker', 'podman'):
        if not e:
            continue
        try:
            subprocess.run([e, '--version'], capture_output=True, timeout=5)
            return e
        except (OSError, subprocess.SubprocessError):
            continue
    return 'docker'


def watcher_running():
    try:
        r = subprocess.run(['pgrep', '-f', 'ks26-watcher.sh'], capture_output=True, timeout=5)
        return r.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def build_state(cfg):
    groups, conf_found = read_conf(cfg['conf'])
    names = [g['name'] for g in groups]
    log_state, tail = parse_log(cfg['log'], names, cfg['timeout'])
    imgmeta = local_images(cfg['engine'], cfg['registry'], cfg['image'])

    images = []
    for g in groups:
        n = g['name']
        s = log_state.get(n, {})
        g.update({k: s.get(k) for k in
                  ('status', 'step', 'step_index', 'step_total', 'elapsed', 'message', 'progress')})
        g['status'] = g['status'] or 'waiting'
        g['timeout'] = cfg['timeout']

        tag_f = os.path.join(cfg['state'], n + '.tag')
        sha_f = os.path.join(cfg['state'], n + '.sha')
        g['tag'] = open(tag_f, encoding='utf-8').read().strip() if os.path.isfile(tag_f) else None
        sha = open(sha_f, encoding='utf-8').read().strip() if os.path.isfile(sha_f) else None
        g['sha'] = sha[:7] if sha else None

        if g['tag']:
            meta = imgmeta.get(g['tag'].rsplit(':', 1)[-1], {})
            try:
                built_at = datetime.fromtimestamp(os.path.getmtime(tag_f)).strftime('%H:%M:%S')
            except OSError:
                built_at = ''
            images.append({'group': n, 'tag': g['tag'], 'sha': g['sha'],
                           'size': meta.get('size', ''), 'built_at': built_at})

    # 把「正在讀哪裡」也送給前端。這個看板曾經被留在驗證沙箱的路徑上,
    # 畫面一切正常、只是資料是假的——那種錯不會自己叫,只能讓它顯示在臉上。
    conf_abs = os.path.abspath(cfg['conf'])
    return {
        'now': datetime.now(timezone.utc).isoformat(timespec='seconds'),
        'live': True,
        'conf': conf_abs,
        'conf_default': os.path.dirname(conf_abs) == HERE,
        'engine': cfg['engine'],
        'registry': cfg['registry'],
        'image': cfg['image'],
        'conf_found': conf_found,
        'watcher_running': watcher_running(),
        'groups': groups,
        'images': images,
        'log': tail,
    }


# 這是公開看板:一場活動可能幾十個人同時開著,每人每 2 秒打一次。
# build_state() 會 fork 一個 `docker images`,不快取的話就是每秒數十次 subprocess,
# 會跟正在跑的建置搶同一台機器的 CPU。快取一秒,N 個觀眾的成本等於 1 個。
_CACHE = {'at': 0.0, 'value': None}
_CACHE_TTL = 1.0


def cached_state(cfg):
    now = time.time()
    if _CACHE['value'] is not None and (now - _CACHE['at']) < _CACHE_TTL:
        return _CACHE['value']
    body = json.dumps(build_state(cfg), ensure_ascii=False)
    _CACHE['at'] = now
    _CACHE['value'] = body
    return body


class Handler(BaseHTTPRequestHandler):
    cfg = None
    protocol_version = 'HTTP/1.1'

    def _send(self, code, body, ctype):
        raw = body.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(raw)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        path = self.path.split('?', 1)[0]
        if path == '/api/state':
            try:
                self._send(200, cached_state(self.cfg), 'application/json; charset=utf-8')
            except Exception as exc:                      # 看板壞掉不該讓人以為建置壞了
                self._send(500, json.dumps({'error': str(exc)}), 'application/json; charset=utf-8')
        elif path in ('/', '/index.html'):
            page = os.path.join(HERE, 'ks26-board.html')
            if not os.path.isfile(page):
                self._send(404, 'ks26-board.html 不在 %s' % HERE, 'text/plain; charset=utf-8')
                return
            self._send(200, open(page, encoding='utf-8').read(), 'text/html; charset=utf-8')
        else:
            self._send(404, 'not found', 'text/plain; charset=utf-8')

    def log_message(self, *args):
        pass                                              # 別把 access log 噴進投影畫面


def main():
    p = argparse.ArgumentParser(description='ks26 建置看板')
    p.add_argument('--port', type=int, default=int(os.environ.get('KS26_BOARD_PORT', 8080)))
    p.add_argument('--bind', default=os.environ.get('KS26_BOARD_BIND', '127.0.0.1'))
    p.add_argument('--conf', default=os.environ.get('KS26_CONF', os.path.join(HERE, 'groups.conf')))
    p.add_argument('--state', default=os.environ.get('KS26_STATE', os.path.join(HERE, 'state')))
    p.add_argument('--log', default=os.environ.get('KS26_LOG', os.path.join(HERE, 'watcher.log')))
    a = p.parse_args()

    Handler.cfg = {
        'conf': a.conf, 'state': a.state, 'log': a.log,
        'registry': os.environ.get('KS26_REGISTRY', 'docker.io/DOCKERHUB_ACCOUNT'),
        'image': os.environ.get('KS26_IMAGE', 'ks26-app'),
        'timeout': int(os.environ.get('KS26_BUILD_TIMEOUT', 180)),
        'engine': detect_engine(),
    }
    srv = ThreadingHTTPServer((a.bind, a.port), Handler)
    print('ks26 建置看板  http://%s:%d' % (a.bind, a.port))
    print('  設定檔 %s' % a.conf)
    print('  狀態   %s' % a.state)
    print('  日誌   %s' % a.log)
    if a.bind == '127.0.0.1':
        print('  從筆電看：ssh -L %d:127.0.0.1:%d ec2-user@<runner>' % (a.port, a.port))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print('\n收工')


if __name__ == '__main__':
    main()
