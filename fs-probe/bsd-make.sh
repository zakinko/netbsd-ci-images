#!/bin/sh
# NetBSD / FreeBSD の上で、その OS 自身の newfs で種類ごとにイメージを作り、
# mktree.sh の中身を入れて、manifest を添える。
#   bsd-make.sh <outdir>
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=$1
mkdir -p "$out" /mnt/p
SIZE_MB=512

fill() {	# name
	sh "$here/mktree.sh" /mnt/p/src
	sh "$here/manifest.sh" /mnt/p/src > "$out/$1.manifest"
	df -k /mnt/p | tail -1 > "$out/$1.df"
}

case $(uname -s) in
NetBSD)
	raw=$(printf "\\$(printf %03o $((97 + $(sysctl -n kern.rawpartition))))")
	one() {	# name newfs-args mount-args
		f=$out/$1.img
		dd if=/dev/zero of="$f" bs=1m count=0 seek=$SIZE_MB 2>/dev/null
		vndconfig vnd0 "$f"
		newfs $2 /dev/rvnd0$raw > "$out/$1.newfs"
		mount $3 /dev/vnd0$raw /mnt/p
		fill "$1"
		umount /mnt/p
		fsck_ffs -n -f /dev/rvnd0$raw > "$out/$1.fsck" 2>&1
		dumpfs -s /dev/rvnd0$raw > "$out/$1.dumpfs" 2>&1 || true
		vndconfig -u vnd0
	}
	one netbsd-ffs1       '-O 1' ''
	one netbsd-ffs2       '-O 2' ''
	one netbsd-ffs2-wapbl '-O 2' '-o log'
	;;
FreeBSD)
	one() {	# name newfs-args
		f=$out/$1.img
		truncate -s ${SIZE_MB}m "$f"
		md=$(mdconfig -a -t vnode -f "$f")
		newfs $2 /dev/$md > "$out/$1.newfs"
		mount /dev/$md /mnt/p
		fill "$1"
		umount /mnt/p
		fsck_ffs -n -f /dev/$md > "$out/$1.fsck" 2>&1
		dumpfs -m /dev/$md > "$out/$1.dumpfs" 2>&1 || true
		mdconfig -d -u $md
	}
	one freebsd-ufs1      '-O 1'
	one freebsd-ufs2      '-O 2'
	one freebsd-ufs2-su   '-O 2 -U'
	one freebsd-ufs2-suj  '-O 2 -j'
	;;
esac
uname -a > "$out/$(uname -s | tr A-Z a-z)-uname"
ls -ls "$out"
