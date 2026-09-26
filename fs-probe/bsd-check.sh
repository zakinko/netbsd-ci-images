#!/bin/sh
# Linux が書き足したイメージを、その OS 自身の fsck_ffs にかけ、Linux が
# 書いたと言っている中身が本当に在るかを manifest で突き合わせる。
#   bsd-check.sh <dir with *.img and *.linux.manifest> <outdir>
set -e
here=$(cd "$(dirname "$0")" && pwd)
in=$1
out=$2
mkdir -p "$out" /mnt/p
case $(uname -s) in
NetBSD)  pat='netbsd-*.img' ;;
FreeBSD) pat='freebsd-*.img' ;;
esac
attach() {
	case $(uname -s) in
	NetBSD)
		raw=$(printf "\\$(printf %03o $((97 + $(sysctl -n kern.rawpartition))))")
		vndconfig vnd0 "$1"; dev=/dev/vnd0$raw; rdev=/dev/rvnd0$raw ;;
	FreeBSD)
		md=$(mdconfig -a -t vnode -f "$1"); dev=/dev/$md; rdev=/dev/$md ;;
	esac
}
detach() {
	case $(uname -s) in
	NetBSD)  vndconfig -u vnd0 ;;
	FreeBSD) mdconfig -d -u $md ;;
	esac
}
for f in $in/$pat; do
	[ -e "$f" ] || continue
	n=$(basename "$f" .img)
	r=$out/$n.check
	{
		echo "== $n"
		attach "$f"
		echo "-- fsck_ffs -n -f"
		fsck_ffs -n -f $rdev 2>&1 && echo "fsck exit 0" || echo "fsck exit $?"
		if mount -r $dev /mnt/p; then
			for sub in src linux; do
				[ -d /mnt/p/$sub ] || continue
				# src は元の OS が入れたもの、linux は Linux が足したもの。
				# src が変わっていれば、Linux が他人の物を壊している。
				case $sub in
				src)   m=$in/$n.manifest ;;
				linux) m=$in/$n.linux.manifest ;;
				esac
				[ -e "$m" ] || continue
				sh "$here/manifest.sh" /mnt/p/$sub > $out/$n.$sub.back
				echo "-- $sub: diff (< 書いた側の manifest, > $(uname -s) で読めたもの)"
				diff $m $out/$n.$sub.back | head -80 || true
				echo "   differing lines: $(diff $m $out/$n.$sub.back | grep -c '^[<>]' || true)"
			done
			umount /mnt/p
		else
			echo "!! mount -r failed"
		fi
		detach
	} > "$r" 2>&1
	cat "$r"
done
