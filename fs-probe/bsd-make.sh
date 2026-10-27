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
ea_fill() {	# name [noacl]
	mkdir /mnt/p/ea
	for i in 1 2 3 4 5 6 7 8; do
		dd if=/dev/random of=/mnt/p/ea/f$i bs=64k count=4 2>/dev/null
		setextattr user probe "attr-$i-$(sha /mnt/p/ea/f$i)" /mnt/p/ea/f$i
	done
	[ "${2:-}" = noacl ] || setfacl -m u:nobody:rwx /mnt/p/ea/f1
	dd if=/dev/random bs=1 count=3000 2>/dev/null | openssl base64 > "$out/big.tmp"
	# -i は FreeBSD では値を標準入力から読み、NetBSD では次の引数の
	# ファイルから読む。
	case $(uname -s) in
	NetBSD) setextattr -i "$out/big.tmp" user big /mnt/p/ea/f2 ;;
	*)      setextattr -i user big /mnt/p/ea/f2 < "$out/big.tmp" ;;
	esac
	rm -f "$out/big.tmp"
	sh "$here/ea-list.sh" /mnt/p/ea > "$out/$1.ea-expect"
}

# sha256 は FreeBSD と NetBSD で道具の名前が違うので openssl で揃える。
sha() { openssl dgst -sha256 -r "$1" | cut -d' ' -f1; }

# 古い fsck に壊された拡張属性の欄を作る。NetBSD 9 以前の fsck は拡張属性
# のブロックを空きに戻すので、di_extb[] が別のファイルのものになった
# ブロックを指したまま残りうる。tests/sbin/fsck_ffs/t_extattr.sh の
# fsck_extattr_enable_corrupted と同じく fsdb で作る。
stale_fill() {	# name
	mkdir /mnt/p/ea
	dd if=/dev/random of=/mnt/p/ea/victim bs=8k count=1 2>/dev/null
	true > /mnt/p/ea/stale
	echo "$(ls -i /mnt/p/ea/victim | awk '{print $1}')" \
	     "$(ls -i /mnt/p/ea/stale | awk '{print $1}')" \
	     "$(sha /mnt/p/ea/victim)" > "$out/$1.stale"
}
stale_point() {	# name rawdev
	set -- $1 $2 $(cat "$out/$1.stale")
	blk=$(printf 'inode %s\niptrs\n' $3 | fsdb -n $2 | awk '$1 == "di_db" && $2 == 0 {print $3}')
	printf 'inode %s\nchextb 0 %s\n' $4 $blk | fsdb -N $2 > /dev/null
	printf 'inode %s\nchextsize 1024\n' $4 | fsdb -N $2 > /dev/null
	echo "$1: stale inode $4 points di_extb[0] at block $blk of victim inode $3"
}

# UFS2ea を普通の UFS2 の magic に戻す。2020-04 から 2022-11 の -current は
# 普通の UFS2 の magic のまま拡張属性を作れたので、その頃の image と同じ
# 状態になる。本体の superblock は 65536、fs_magic は 1372 (fs.h)。
ea_as_plain_ufs2() {	# image
	off=$((65536 + 1372))
	cur=$(dd if="$1" bs=1 skip=$off count=4 2>/dev/null | od -An -tx1 | tr -d ' ')
	[ "$cur" = 38200119 ] || { echo "!! $1: fs_magic is $cur, not UFS2ea"; return 1; }
	printf '\031\001\124\031' | dd of="$1" bs=1 seek=$off conv=notrunc 2>/dev/null
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
		case $1 in
		*-ea-current) ea_fill "$1" noacl ;;
		*-stale) stale_fill "$1" ;;
		esac
		umount /mnt/p
		case $1 in *-stale) stale_point "$1" /dev/rvnd0$raw ;; esac
		fsck_ffs -n -f /dev/rvnd0$raw > "$out/$1.fsck" 2>&1 ||
			echo "$1: fsck_ffs -n exit $?: $(grep -vE '^\*\*' "$out/$1.fsck" | head -3 | tr '\n' ';')"
		dumpfs -s /dev/rvnd0$raw > "$out/$1.dumpfs" 2>&1 || true
		dumpfs -s /dev/rvnd0$raw 2>&1 | grep -iE "^flags|quota" | sed "s/^/$1: /"
		vndconfig -u vnd0
		case $1 in *-ea-current) ea_as_plain_ufs2 "$f" ;; esac
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
	# 2020-04 から 2022-11 の -current が作った、普通の UFS2 の magic で拡張
	# 属性を持つ FS。FreeBSD の拡張属性つき UFS2 と同じ形になる。
	one netbsd-ffs2-ea-current '-O 2ea' ''
	# その FS が古い fsck にかけられて、di_extb[] が他人のブロックを指した
	# まま残ったもの。
	one netbsd-ffs2-stale  '-O 2' ''
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
