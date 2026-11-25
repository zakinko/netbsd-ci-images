#!/usr/bin/python3
# ntfs3 に symlink を作り、書いたとおりに返るかを数える。
#   ntfs3-colon-links.py make|check <dir> <tag> [latin1]
# '\' は ntfs3 が '/' に直して返すので、その分は合っているものとして数える。
import errno
import os
import sys

mode, d, tag = sys.argv[1], os.fsencode(sys.argv[2]), sys.argv[3]
latin1 = len(sys.argv) > 4

T = [
    b'x', b'rel/x', b'/abs/x',
    # ':' の位置を全部
    b'a:b', b':a', b'a:', b':', b'::', b'a::b', b'a:b:c', b'ab:c', b'abc:d',
    b'a:b/c', b'dir/a:b', b'../a:b', b'/abs/a:b', b'a/b:c/d:e',
    # ドライブに見えるもの
    b'C:', b'C:x', b'C:/x', b'C:\\x', b'c:/', b'1:/x', b'C:/dir/a:b',
    b'CC:/x', b'//server/share/x',
    # 長いもの。u8 の長さ欄 (255) の前後と、reparse の上限の近く
    b'a' * 300 + b':' + b'b' * 300,
    b'a' * 254 + b':b', b'a' * 255 + b':b', b'a' * 256 + b':b',
    b'a:' + b'b' * 253, b'a:' + b'b' * 254, b'a:' + b'b' * 255,
    b'a:' + b'b' * 256, b'a:' + b'b' * 1000, b'ab:' * 600,
    b'a' * 4000 + b':b', b'd/' * 1500 + b'a:b',
    # UTF-8
    '\u65e5\u672c:\u8a9e'.encode(), '\u00e9:\u00e8'.encode(),
    '\u65e5\u672c\u8a9e/\u30d5\u30a1\u30a4\u30eb:\u540d\u524d'.encode(),
    '\U0001f600:\U0001f600'.encode(),
    ('\u3042' * 200 + ':' + '\u3044' * 200).encode(),
]
if latin1:
    T += [b'\xe9:\xe8', b'a:\xff', b'\xc0' * 300 + b':' + b'\xff' * 300]


def show(b):
    s = repr(b)[2:-1]
    return (s if len(s) <= 48 else s[:30] + '...' + s[-12:]) + ' (%d)' % len(b)


made = errs = bad = 0
lines = []
for i, t in enumerate(T):
    p = os.path.join(d, b'l%03d' % i)
    if mode == 'make':
        try:
            os.symlink(t, p)
        except OSError as e:
            errs += 1
            lines.append('  create error %s: %s' % (show(t), errno.errorcode.get(e.errno, e.errno)))
            continue
    try:
        r = os.readlink(p)
    except FileNotFoundError:
        continue
    except OSError as e:
        bad += 1
        lines.append('  MISMATCH %s -> readlink %s' % (show(t), errno.errorcode.get(e.errno, e.errno)))
        continue
    made += 1
    if r != t.replace(b'\\', b'/'):
        bad += 1
        lines.append('  MISMATCH %s -> %s' % (show(t), show(r)))
print('links %s: %d targets, %d read, %d create errors, %d mismatches' % (tag, len(T), made, errs, bad))
print('\n'.join(lines)) if lines else None
