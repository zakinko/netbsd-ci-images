# . で読む。superblock の値を一つずつ壊した image を mount して、断られる
# か、カーネルが落ちる (Oops や UBSAN を出す) かを並べる。
# 使い方: crafted_run ラベル
# CRAFTED_SKIP に名前を並べると、その場合は mount しない。
# 欄の位置は FreeBSD の sys/ufs/ffs/fs.h による (fs/ufs/ufs_fs.h の
# offsetof でも同じ): fs_bsize 48, fs_fsize 52, fs_frag 56, fs_fmask 76,
# fs_fshift 84, fs_sbsize 104, fs_cgsize 160。UFS2 の superblock は 65536。
crafted_cases='
freebsd-ufs2 sbsize-1306 104=1306
freebsd-ufs2 fshift-20 84=20
freebsd-ufs2 cgsize-64k 160=65536
freebsd-ufs2 frag-16 56=16
netbsd-ffs2 sbsize-1k-of-8k-1k 48=8192 52=1024 76=4294966272 84=10 104=1024
'
crafted_poke() {	# image off=value ...
	python3 -I - "$@" <<'PY'
import struct, sys
with open(sys.argv[1], 'r+b') as f:
    for a in sys.argv[2:]:
        off, val = (int(x) for x in a.split('='))
        f.seek(65536 + off)
        f.write(struct.pack('<I', val))
PY
}
crafted_run() {	# label
	note "crafted superblocks ($1): mount exit, then what the kernel said"
	echo "$crafted_cases" | while read img name pokes; do
		[ -n "$img" ] && [ -e $in/$img.img ] || continue
		case " ${CRAFTED_SKIP:-} " in *" $name "*)
			note "  $img $name: skipped"; continue ;;
		esac
		c=$work/crafted.img
		cp --sparse=always $in/$img.img $c
		crafted_poke $c $pokes
		cl=$(losetup -f --show $c)
		timeout 60 mount -t ufs -o ro,ufstype=ufs2 $cl /mnt/p 2>/dev/null
		rc=$?
		mountpoint -q /mnt/p && umount /mnt/p
		losetup -d $cl
		rm -f $c
		dmesg -c > $out/crafted-$1-$name.dmesg
		bad=$(grep -cE 'BUG|Oops|general protection|UBSAN|KASAN|Call Trace' $out/crafted-$1-$name.dmesg)
		note "  $img $name: exit $rc, oops lines $bad, $(grep -m1 'ufs' $out/crafted-$1-$name.dmesg | sed 's/^\[[^]]*\] //')"
	done
}

# quota2 ファイルの header を壊して rw で mount し、書かせる。断られるか、
# 黙って header を上書きするか、カーネルが落ちるかを並べる。header の
# sha256 を、壊した直後と umount の後とで比べる (shift を壊した場合は
# header として読めないので比べない)。
#   shift-16          q2h_hash_shift を 16 にする (hash_size は u16 で入らない)
#   head-into-header  uid 0 の hash の鎖の頭を header の中 (16) に向ける
#   free-into-header  空き entry の鎖の頭を header の中 (8) に向ける
crafted_q2_cases='
shift-16 shift=16
head-into-header head0=16
free-into-header free=8
'
crafted_q2_run() {	# label
	local img=netbsd-ffs2-quota2 c cl rc wr before after bad
	[ -e $in/$img.img ] || return 0
	note "crafted quota2 headers ($1): mount exit, write exit, header before/after, what the kernel said"
	echo "$crafted_q2_cases" | while read name pokes; do
		[ -n "$name" ] || continue
		c=$work/crafted.img
		cp --sparse=always $in/$img.img $c
		python3 -I $here/q2poke.py $c 0 $pokes
		before=$(python3 -I $here/q2poke.py $c 0 sum 2>&1 | sed 's/.*sha256 //')
		cl=$(losetup -f --show $c)
		timeout 60 mount -t ufs -o rw,ufstype=ufs2 $cl /mnt/p 2>/dev/null
		rc=$? wr=-
		if mountpoint -q /mnt/p; then
			# root (uid 0) の分を数えさせ、まだ entry の無い 4242 に渡す。
			timeout 60 sh -c 'echo x > /mnt/p/q2probe && chown 4242 /mnt/p/q2probe && sync' 2>/dev/null
			wr=$?
			umount /mnt/p
		fi
		losetup -d $cl
		after=$(python3 -I $here/q2poke.py $c 0 sum 2>&1 | sed 's/.*sha256 //')
		rm -f $c
		dmesg -c > $out/crafted-q2-$1-$name.dmesg
		bad=$(grep -cE 'BUG|Oops|general protection|UBSAN|KASAN|Call Trace' $out/crafted-q2-$1-$name.dmesg)
		note "  $name: mount $rc, write $wr, header $before -> $after, oops lines $bad, $(grep -m1 'ufs' $out/crafted-q2-$1-$name.dmesg | sed 's/^\[[^]]*\] //')"
	done
}
