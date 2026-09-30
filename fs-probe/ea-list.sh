#!/bin/sh
# $1 の下のファイルについて、拡張属性 user.probe と user.big (中身の
# sha256) と、ACL に nobody が居るかを一行ずつ書き出す。属性が無ければ
# 空にする。FreeBSD と NetBSD の getextattr / getfacl で同じに走る。
cd "$1" || exit 1
for f in *; do
	[ -f "$f" ] || continue
	probe=$(getextattr -q user probe "$f" 2>/dev/null)
	big=
	if b=$(getextattr -q user big "$f" 2>/dev/null); then
		big=$(printf '%s' "$b" | sha256 -q)
	fi
	acl=$(getfacl -q "$f" 2>/dev/null | grep -c nobody)
	printf '%s probe=%s big=%s acl=%s\n' "$f" "$probe" "$big" "${acl:-0}"
done
