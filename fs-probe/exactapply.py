#!/usr/bin/env python3
# 当て物の組を順に当て、どの hunk も書いた行で文脈が一字一句合うかを確かめる。
# macOS の /usr/bin/patch は offset も fuzz も表示せずに当てるので、手元での
# 確かめにはこれを使う (2026-11-11)。CI では ufs-crash.sh の prefix 段が数える。
#   exactapply.py [--fix] <木の根> <当て物>...
# --fix は、ずれだけの hunk の頭の行番号を書き直す。
import re
import sys

fix = sys.argv[1] == "--fix"
if fix:
	del sys.argv[1]
root = sys.argv[1]
bad = 0


def hunks(lines):
	i = 0
	cur = None
	while i < len(lines):
		l = lines[i]
		if l.startswith("+++ "):
			cur = l[4:].split("\t")[0].strip()
			cur = cur[2:] if cur.startswith("b/") else cur
			i += 1
			continue
		m = re.match(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", l)
		if not m:
			i += 1
			continue
		hdr = i
		o, oc = int(m[1]), int(m[2] if m[2] is not None else 1)
		nc = int(m[4] if m[4] is not None else 1)
		old, new = [], []
		i += 1
		while i < len(lines) and (len(old) < oc or len(new) < nc):
			t = lines[i]
			if t.startswith("\\"):
				i += 1
				continue
			c, body = t[:1], t[1:]
			if c in (" ", ""):
				old.append(body)
				new.append(body)
			elif c == "-":
				old.append(body)
			elif c == "+":
				new.append(body)
			else:
				break
			i += 1
		yield cur, o, old, new, hdr


for p in sys.argv[2:]:
	name = p.rsplit("/", 1)[-1]
	files = {}
	shift = {}
	plines = open(p).read().split("\n")
	for f, o, old, new, hdr in hunks(plines):
		if f not in files:
			try:
				files[f] = open(root + "/" + f).read().split("\n")
			except FileNotFoundError:
				files[f] = [""]
			shift[f] = 0
		buf = files[f]
		at = (o - 1 if old else o) + shift[f]
		if buf[at:at + len(old)] != old:
			off = None
			for d in range(1, 400):
				for s in (at + d, at - d):
					if 0 <= s and buf[s:s + len(old)] == old:
						off = s - at
						break
				if off is not None:
					break
			print("%s: %s hunk @-%d does not match exactly (offset %s)" % (name, f, o, off))
			bad += 1
			if off is None:
				continue
			at += off
			if fix:
				m = re.match(r"@@ -(\d+)(,\d+)? \+(\d+)(,\d+)? @@(.*)$", plines[hdr])
				plines[hdr] = "@@ -%d%s +%d%s @@%s" % (int(m[1]) + off, m[2] or "", int(m[3]) + off, m[4] or "", m[5])
		buf[at:at + len(old)] = new
		shift[f] += len(new) - len(old)
	for f, buf in files.items():
		open(root + "/" + f, "w").write("\n".join(buf))
	if fix:
		open(p, "w").write("\n".join(plines))
print("mismatches:", bad)
sys.exit(1 if bad else 0)
