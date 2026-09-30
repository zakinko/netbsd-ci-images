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
	# mktree は作れなかった数を exit で返す。set -e で黙って落ちないよう、
	# 何が作れなかったかを残して先へ進む。
	sh "$here/mktree.sh" /mnt/p/src 2> "$out/$1.mktree" ||
		echo "$1: mktree: $(grep -c FAIL "$out/$1.mktree") FAIL; $(grep FAIL "$out/$1.mktree" | head -3 | tr '\n' ';')"
	sh "$here/manifest.sh" /mnt/p/src > "$out/$1.manifest"
	df -k /mnt/p | tail -1 > "$out/$1.df"
}

# 拡張属性つきのファイルを ea/ の下に置き、その値を ea-expect に書く。
# f2 には 1 ブロックを越える属性、f1 には ACL。作り方は ci-images の
# ufs2-quota-probe 枝の ufs2-probe/mkimg.sh に倣った。
ea_fill() {	# name
	mkdir /mnt/p/ea
	for i in 1 2 3 4 5 6 7 8; do
		dd if=/dev/random of=/mnt/p/ea/f$i bs=64k count=4 2>/dev/null
		setextattr user probe "attr-$i-$(sha256 -q /mnt/p/ea/f$i)" /mnt/p/ea/f$i
	done
	setfacl -m u:nobody:rwx /mnt/p/ea/f1
	dd if=/dev/random bs=1 count=3000 2>/dev/null | b64encode - | tail -n +2 > "$out/big.tmp"
	setextattr -i user big /mnt/p/ea/f2 < "$out/big.tmp"
	rm -f "$out/big.tmp"
	sh "$here/ea-list.sh" /mnt/p/ea > "$out/$1.ea-expect"
}

case $(uname -s) in
NetBSD)
	raw=$(printf "\\$(printf %03o $((97 + $(sysctl -n kern.rawpartition))))")
	one() {	# name newfs-args mount-args
		f=$out/$1.img
		# vnd の raw partition は種別が 4.2BSD でないので newfs が断る。
		# ファイルへ直に作ってから vnd に付ける。
		dd if=/dev/zero of="$f" bs=1m count=0 seek=$SIZE_MB 2>/dev/null
		newfs -F -s ${SIZE_MB}m $2 "$f" > "$out/$1.newfs"
		vndconfig vnd0 "$f"
		mount $3 /dev/vnd0$raw /mnt/p
		fill "$1"
		umount /mnt/p
		fsck_ffs -n -f /dev/rvnd0$raw > "$out/$1.fsck" 2>&1 ||
			echo "$1: fsck_ffs -n exit $?: $(grep -vE '^\*\*' "$out/$1.fsck" | head -3 | tr '\n' ';')"
		dumpfs -s /dev/rvnd0$raw > "$out/$1.dumpfs" 2>&1 || true
		dumpfs -s /dev/rvnd0$raw 2>&1 | grep -iE "^flags|quota" | sed "s/^/$1: /"
		vndconfig -u vnd0
	}
	one netbsd-ffs1       '-O 1' ''
	one netbsd-ffs2       '-O 2' ''
	one netbsd-ffs2-wapbl '-O 2' '-o log'
	# 0x200 は NetBSD では FS_DOQUOTA2、FreeBSD では FS_METACKHASH。
	# Linux がこれを取り違えて落とさないかを見るための一枚。
	one netbsd-ffs2-quota2 '-O 2 -q user -q group' ''
	# UFS2ea は拡張属性を知らない実装に mount させないための別の magic。
	# Linux が rw で断ることを確かめる。
	one netbsd-ffs2ea      '-O 2ea' ''
	;;
FreeBSD)
	one() {	# name newfs-args
		f=$out/$1.img
		truncate -s ${SIZE_MB}m "$f"
		md=$(mdconfig -a -t vnode -f "$f")
		newfs $2 /dev/$md > "$out/$1.newfs"
		case $1 in *-ea) tunefs -a enable /dev/$md > /dev/null ;; esac
		mount /dev/$md /mnt/p
		fill "$1"
		case $1 in *-ea) ea_fill "$1" ;; esac
		umount /mnt/p
		fsck_ffs -n -f /dev/$md > "$out/$1.fsck" 2>&1 ||
			echo "$1: fsck_ffs -n exit $?: $(grep -vE '^\*\*' "$out/$1.fsck" | head -3 | tr '\n' ';')"
		dumpfs -m /dev/$md > "$out/$1.dumpfs" 2>&1 || true
		dumpfs /dev/$md 2>&1 | sed -n "1,40p" | grep -iE "flags|hash|magic" | sed "s/^/$1: /"
		mdconfig -d -u $md
	}
	one freebsd-ufs1      '-O 1'
	one freebsd-ufs2      '-O 2'
	one freebsd-ufs2-su   '-O 2 -U'
	one freebsd-ufs2-suj  '-O 2 -j'
	# 拡張属性と ACL は普通の UFS2 の magic のまま di_extb[] に入る。Linux は
	# di_extb を知らないので、消したときに解放するかを見るための一枚。
	one freebsd-ufs2-ea   '-O 2'
	;;
esac
uname -a > "$out/$(uname -s | tr A-Z a-z)-uname"
ls -ls "$out"
