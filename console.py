#!/usr/bin/env python3
"""QEMU のシリアルを記録し、決まった問いにだけ答える。

普段はシリアルをファイルに落とすだけで足りる (runvm.sh の -serial file:)。
困るのは macppc で、こちらは起動のたびにカーネルが

    root device (default cd0a):

と聞いてくる。FFS から起動できないので CD のカーネルで起こしていて、
root だけディスクを使うため、その食い違いを人が埋める作りになっている。
anita は install のときに同じことをコンソール越しに答えている。

答えるには読むだけでなく書ける口が要るので、file: ではなく unix: で
繋いで、こちらから流し込む。

    console.py --socket path --log file --answer 'root device:=>wd0a' ...

--answer は書いた順に一つずつ使う。同じ語がログの後ろのほうで再び出ても
二度は答えない。
"""

import argparse
import os
import re
import socket
import sys
import time


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--socket', required=True)
    p.add_argument('--log', required=True)
    p.add_argument('--answer', action='append', default=[],
                   metavar='REGEXP=>REPLY')
    p.add_argument('--timeout', type=float, default=1800.0)
    args = p.parse_args()

    answers = []
    for a in args.answer:
        pat, _, reply = a.partition('=>')
        if pat:
            answers.append((re.compile(pat), reply))

    # qemu が socket を作るまで待つ。-daemonize と競走になる。
    deadline = time.time() + 60
    s = None
    while time.time() < deadline:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(args.socket)
            break
        except OSError:
            s.close()
            s = None
            time.sleep(0.5)
    if s is None:
        print("console.py: %s に繋がらない" % args.socket, file=sys.stderr)
        return 1

    log = open(args.log, 'ab', buffering=0)
    s.settimeout(1.0)
    buf = b''
    end = time.time() + args.timeout
    while time.time() < end:
        try:
            data = s.recv(4096)
        except socket.timeout:
            continue
        except OSError:
            break
        if not data:
            break
        log.write(data)
        # 問いはプロンプトなので改行では終わらない。行に頼らず、
        # 直前の一塊を見る。
        buf = (buf + data)[-4096:]
        if answers:
            pat, reply = answers[0]
            text = buf.decode('latin-1')
            if pat.search(text):
                s.sendall((reply + "\r\n").encode('latin-1'))
                log.write(("\n[console.py] %s -> %s\n"
                           % (pat.pattern, reply or '(改行だけ)')).encode())
                answers.pop(0)
                buf = b''
    return 0


if __name__ == '__main__':
    sys.exit(main())
