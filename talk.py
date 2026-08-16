#!/usr/bin/env python3
"""シリアルに繋いで、待っては打つ、を順にやる。

console.py が「起動のたびに聞かれる決まった問いに答える」ものなのに対し、
こちらは手順を順番に流すためのもの。

    talk.py --socket S --log L --step 'login:=>root' --step '#=>uname -a'

手で通した手順をそのまま並べれば、それがレシピになる。実際 SunOS 4.1.4 は

    login:  -> root                      (パスワード無し)
    #       -> ifconfig le0 10.0.2.15 …  (IP が固定で焼かれていて qemu の
    #       -> route add default 10.0.2.2  user networking と噛み合わない)

の三手でホストから届くようになった。

--kick は繋いだ直後に改行を一つ送る。起動の途中から見ているときは何か流れて
くるが、既に上がっているものに繋ぎ直したときは誰も喋っていないので、促しを
出させないと最初の一手が始まらない。
"""
import argparse
import re
import socket
import sys
import time


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--socket', required=True)
    p.add_argument('--log', required=True)
    p.add_argument('--step', action='append', default=[], metavar='REGEXP=>TEXT')
    p.add_argument('--timeout', type=float, default=180.0)
    # 促しが出てから打つまでの間。古い機械では促しの直後はまだ読む用意が
    # 出来ていないことがあり、続けて打つと最初の何文字かが落ちる。
    p.add_argument('--settle', type=float, default=0.5)
    p.add_argument('--kick', action='store_true')
    args = p.parse_args()

    steps = []
    for s in args.step:
        pat, _, text = s.partition('=>')
        steps.append((re.compile(pat), text))

    # qemu が socket を作るまで待つ。-daemonize と競走になる。
    end = time.time() + 60
    sk = None
    while time.time() < end:
        try:
            sk = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sk.connect(args.socket)
            break
        except OSError:
            sk.close()
            sk = None
            time.sleep(0.5)
    if sk is None:
        print("talk.py: %s に繋がらない" % args.socket, file=sys.stderr)
        return 1

    log = open(args.log, 'ab', buffering=0)
    sk.settimeout(1.0)
    if args.kick:
        sk.sendall(b'\n')

    buf = b''
    deadline = time.time() + args.timeout
    while steps and time.time() < deadline:
        try:
            data = sk.recv(4096)
        except socket.timeout:
            continue
        except OSError:
            break
        if not data:
            break
        log.write(data)
        # 促しは改行で終わらないので、行ではなく直前の一塊を見る。
        buf = (buf + data)[-8192:]
        pat, text = steps[0]
        if pat.search(buf.decode('latin-1')):
            time.sleep(args.settle)
            sk.sendall((text + "\n").encode('latin-1'))
            print("[talk] %-24s -> %s" % (pat.pattern, text or '(改行)'))
            sys.stdout.flush()
            log.write(("\n[talk] %s -> %s\n" % (pat.pattern, text)).encode())
            steps.pop(0)
            buf = b''

    # 打ち終えた後の出力も少し拾う。結果はたいてい最後の一手の後に出る。
    tail = time.time() + 15
    while time.time() < tail:
        try:
            data = sk.recv(4096)
        except (socket.timeout, OSError):
            continue
        if not data:
            break
        log.write(data)

    if steps:
        print("talk.py: 待ちきれなかった: %s" % steps[0][0].pattern,
              file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
