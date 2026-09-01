#!/usr/bin/env python3
"""QEMU のモニタに繋いで、ゲストの画面を一枚 PPM に落とす。

    screendump.py <モニタの socket> <出す先.ppm>

シリアルに何も出さないゲストの様子を見る唯一の手。焼いたイメージの
コンソールを VGA のままにしてあるもの (Vultr 向けなど) はこれで見る。
"""
import os
import socket
import sys
import time

if len(sys.argv) != 3:
    raise SystemExit(__doc__)

s = socket.socket(socket.AF_UNIX)
try:
    s.connect(sys.argv[1])
except OSError as e:
    raise SystemExit("screendump.py: %s に繋がらない (%s)" % (sys.argv[1], e))
s.settimeout(3)
try:
    s.recv(4096)          # 挨拶を読み捨てる
except Exception:
    pass
s.sendall(b"screendump " + os.path.abspath(sys.argv[2]).encode() + b"\n")
# 書き終わるのを待つ。返事は見ない (モニタは promptを返すだけ)。
time.sleep(4)
