#!/usr/bin/env python3
"""ゲストに配るものと、名前を付け替えた配布ツリーを、同じポートから出す。

二つの役目がある。

一つ目。ゲストは起動のたびに http://10.0.2.2:8123/authorized_keys を
取りに来る (guest-bootstrap.sh が置く /etc/rc.d/seed_key)。イメージに鍵を
焼かないための仕掛けで、そのぶん配る側がどこかで待っている必要がある。

二つ目。anita は配布ツリーの URL の最後の要素を、そのまま port の名前
として読む (anita.py の class URL)。ところが release ツリーでの名前は
anita が期待する名前といつも同じではない。

    hppa                6.0 より前は hp700 という名前だった
    evbarm-earmv7hf     release ツリーには無く daily にしかない
    riscv-riscv64       同上

ミラーを丸ごと持ってくるわけにはいかないので、302 を返すだけの中継を
手元に立てて、anita には名前を揃えた URL を見せる。中身は本家から
そのまま取られる。

    mirror-alias.py --port 8123 --dir <配るもの> \\
        --alias hppa=https://archive.netbsd.org/pub/NetBSD-archive/NetBSD-5.2.3/hp700/
"""

import argparse
import http.server
import os
import sys
import urllib.parse


def make_handler(directory, aliases):
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=directory, **kw)

        # 付け替えの対象なら 302、そうでなければ手元のファイル。
        def redirect_target(self):
            path = urllib.parse.urlparse(self.path).path.lstrip('/')
            for name, upstream in aliases.items():
                if path == name or path.startswith(name + '/'):
                    rest = path[len(name):].lstrip('/')
                    return upstream.rstrip('/') + '/' + rest
            return None

        def do_GET(self):
            target = self.redirect_target()
            if target is None:
                return super().do_GET()
            self.send_response(302)
            self.send_header('Location', target)
            self.send_header('Content-Length', '0')
            self.end_headers()

        def do_HEAD(self):
            target = self.redirect_target()
            if target is None:
                return super().do_HEAD()
            self.send_response(302)
            self.send_header('Location', target)
            self.send_header('Content-Length', '0')
            self.end_headers()

        # 既定の書式は時刻が付かない。どちらが先に来たのかを後から
        # 追えるようにしておく。
        def log_message(self, fmt, *args):
            sys.stderr.write("%s %s\n" % (self.log_date_time_string(),
                                          fmt % args))
            sys.stderr.flush()

    return Handler


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--port', type=int, default=8123)
    p.add_argument('--dir', default='.')
    p.add_argument('--alias', action='append', default=[],
                   metavar='NAME=URL')
    args = p.parse_args()

    aliases = {}
    for a in args.alias:
        name, _, url = a.partition('=')
        if not url:
            p.error("--alias は NAME=URL の形で渡すこと: %s" % a)
        aliases[name] = url

    os.makedirs(args.dir, exist_ok=True)
    handler = make_handler(os.path.abspath(args.dir), aliases)
    # ゲストからは 10.0.2.2 として見えるので、127.0.0.1 だけでは届かない。
    httpd = http.server.ThreadingHTTPServer(('0.0.0.0', args.port), handler)
    for name, url in aliases.items():
        print("alias /%s/ -> %s" % (name, url), file=sys.stderr)
    print("listening on %d, serving %s" % (args.port, args.dir),
          file=sys.stderr)
    sys.stderr.flush()
    httpd.serve_forever()


if __name__ == '__main__':
    main()
