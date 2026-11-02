# . で読む。superblock の値を一つずつ壊した image を mount して、断られる
# か、カーネルが落ちる (Oops や UBSAN を出す) かを並べる。
# 使い方: crafted_run ラベル
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
