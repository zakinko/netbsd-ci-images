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
import os
import pty
import re
import select
import shlex
import signal
import socket
import sys
import time

# 照合の前に落とす制御列。ブートローダのメニューは色や桁送りを挟むので、
# 生のままでは "Cons: Dual" が "C" ESC[0m "ons: Dual" のように割れていて、
# 素直に書いた正規表現が当たらない。記録には生のまま残す。
ANSI = re.compile(r'\x1b\[[0-9;?]*[a-zA-Z]|\x1b[()][A-Za-z0-9]|[\x00\x07\r]')


class Sock:
    """qemu の -serial unix:… に繋ぐ。"""

    def __init__(self, path):
        end = time.time() + 60
        self.s = None
        while time.time() < end:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(path)
                self.s = s
                break
            except OSError:
                s.close()
                time.sleep(0.5)
        if self.s is None:
            raise SystemExit("talk.py: %s に繋がらない" % path)
        self.s.settimeout(1.0)

    def recv(self):
        try:
            return self.s.recv(4096)
        except socket.timeout:
            return b''
        except OSError:
            return b''

    def send(self, b):
        self.s.sendall(b)


class Spawn:
    """emulator を pty の上で起こして、その端末と話す。

    -nographic の qemu を「標準出力をファイルに、標準入力を FIFO に」で
    回すと、出力がブロックバッファに溜まったまま出てこない。起動の最初の
    数百バイトしか喋らない相手 (MidnightBSD の boot2 は 600 バイトほど) では
    一文字も届かないまま待ち続けることになる。端末に繋がっていれば行ごとに
    流れる。ついでに FIFO の開き順を気にしなくてよくなる。
    """

    def __init__(self, command, logpath):
        argv = shlex.split(command)
        self.log = open(logpath, 'ab', buffering=0)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            try:
                os.execvp(argv[0], argv)
            finally:
                os._exit(127)

    def recv(self):
        r, _, _ = select.select([self.fd], [], [], 1.0)
        if not r:
            return b''
        try:
            data = os.read(self.fd, 4096)
        except OSError:
            return b''
        if data:
            self.log.write(data)
        return data

    def send(self, b):
        os.write(self.fd, b)

    def close(self):
        try:
            os.kill(self.pid, signal.SIGTERM)
        except OSError:
            pass


class Pipes:
    """qemu の -nographic を、書き出し先のファイルと FIFO 越しに使う。

    x86 の firmware は VGA があるとそちらにしか出さず、-serial に socket を
    宛てても一文字も来ない。-nographic のときだけシリアルに出る。ところが
    -nographic は標準入出力を使うので、socket では繋げない。そこで qemu の
    標準出力をファイルに、標準入力を FIFO にして、こちらから流し込む。
    """

    def __init__(self, outfile, infile):
        end = time.time() + 60
        while not os.path.exists(outfile) and time.time() < end:
            time.sleep(0.2)
        self.f = open(outfile, 'rb')
        # FIFO は読む側 (qemu) が開くまで開けない。先に qemu を起こすこと。
        self.w = open(infile, 'wb', buffering=0)

    def recv(self):
        d = self.f.read()
        if not d:
            time.sleep(0.3)
        return d or b''

    def send(self, b):
        self.w.write(b)


def unescape(text):
    """打つ文字の中の \\e \\r \\t を本物にする。

    ブートローダによっては ESC や CR そのものが要る。FreeBSD のメニューは
    LF では進まず CR を待つし、DragonFly のメニューには console を切り替える
    項目が無いので、ESC で loader の促しに落とすことになる。
    """
    return (text.replace('\\e', '\x1b')
                .replace('\\r', '\r')
                .replace('\\t', '\t'))


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--socket')
    p.add_argument('--spawn', help='emulator を pty の上で起こす (これを渡すと '
                                   'そのまま起動まで面倒を見る)')
    p.add_argument('--outfile', help='-nographic の書き出し先')
    p.add_argument('--infile', help='-nographic の読み込み元 (FIFO)')
    p.add_argument('--log', required=True)
    p.add_argument('--step', action='append', default=[], metavar='REGEXP=>TEXT')
    p.add_argument('--timeout', type=float, default=180.0)
    # 促しが出てから打つまでの間。古い機械では促しの直後はまだ読む用意が
    # 出来ていないことがあり、続けて打つと最初の何文字かが落ちる。
    p.add_argument('--settle', type=float, default=0.5)
    p.add_argument('--kick', action='store_true')
    # 一文字ずつ送る。古いブートローダは続けて流し込むと取りこぼす。
    # FreeBSD の loader は set console="comconsole" の途中で文字を落とし、
    # 閉じ引用符を待ったまま止まった。
    p.add_argument('--slow', type=float, default=0.0, metavar='秒')
    args = p.parse_args()

    steps = []
    for s in args.step:
        pat, _, text = s.partition('=>')
        steps.append((re.compile(pat), unescape(text)))

    if args.spawn:
        io = Spawn(args.spawn, args.log)
    elif args.socket:
        io = Sock(args.socket)
    elif args.outfile and args.infile:
        io = Pipes(args.outfile, args.infile)
    else:
        raise SystemExit("talk.py: --socket か --outfile/--infile のどちらかが要る")

    # 書き出し先そのものが記録になっている場合は二重に書かない。
    log = None
    if args.spawn:
        pass
    elif args.log != args.outfile:
        log = open(args.log, 'ab', buffering=0)
    if args.kick:
        io.send(b'\n')

    buf = b''
    deadline = time.time() + args.timeout
    while steps and time.time() < deadline:
        data = io.recv()
        if not data:
            continue
        if log:
            log.write(data)
        # 促しは改行で終わらないので、行ではなく直前の一塊を見る。
        buf = (buf + data)[-8192:]
        pat, text = steps[0]
        clean = ANSI.sub('', buf.decode('latin-1'))
        m = pat.search(clean)
        if m:
            time.sleep(args.settle)
            # 制御文字で終わっているなら、それが打鍵そのもの。改行を足すと
            # 余計な一打になる。
            if text[-1:] in ('\x1b', '\r', '\n'):
                payload = text.encode('latin-1')
            else:
                payload = (text + "\n").encode('latin-1')
            if args.slow:
                for ch in payload:
                    io.send(bytes([ch]))
                    time.sleep(args.slow)
            else:
                io.send(payload)
            print("[talk] %-24s -> %s" % (pat.pattern, text or '(改行)'))
            sys.stdout.flush()
            if log:
                log.write(("\n[talk] %s -> %s\n" % (pat.pattern, text)).encode())
            steps.pop(0)
            # 当たった所より後ろは残す。捨てると、同じ一塊に入っていた次の
            # 促しまで消える。MidnightBSD の boot: が実際にそれで消えた。
            buf = clean[m.end():].encode('latin-1')

    # 打ち終えた後の出力も少し拾う。結果はたいてい最後の一手の後に出る。
    tail = time.time() + 15
    while time.time() < tail:
        data = io.recv()
        if data and log:
            log.write(data)

    if steps:
        print("talk.py: 待ちきれなかった: %s" % steps[0][0].pattern,
              file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
