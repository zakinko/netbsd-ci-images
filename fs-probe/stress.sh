#!/bin/sh
# NTFS のドライバそれぞれに、xfstests の fsx と fsstress を同じ条件でかける。
#   stress.sh <outdir>
# alma.sh は決まった木を一度書くだけで、別の実装の穴を探すには足りない。
# fsx は自分の持つ写しと読み戻しを突き合わせるので、化けたらその場で
# 止まる。fsstress には答が無いので、後で remount の前後の中身、
# ntfsfix -n、dmesg、Windows の chkdsk (win-check.ps1) で確かめる。
# 出来たイメージは stress-<drv>.vhd として outdir に置く。
set -u
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$1"
out=$(cd "$1" && pwd)
work=/var/tmp/fsp
mkdir -p $work /mnt/p
sum=$out/summary.txt
: > $sum
note() { printf '%s\n' "$*" | tee -a $sum; }
KV=$(uname -r)
note "# stress / kernel $KV"

dnf -y -q install epel-release
dnf -y -q install patch ntfs-3g ntfsprogs qemu-img gcc make git autoconf \
	automake libtool libuuid-devel xfsprogs-devel libaio-devel libacl-devel \
	libattr-devel \
	elfutils-libelf-devel rpm cpio xz tar bison flex
# fsx と fsstress は xfstests の ltp/ に在る。版を固定し、何で測ったかを残す。
xfstests_tag=v2026.10.15
git clone -q --depth 1 --branch $xfstests_tag \
	https://git.kernel.org/pub/scm/fs/xfs/xfstests-dev.git $work/xfstests
note "xfstests: $(git -C $work/xfstests log -1 --format='%h %cd' --date=short)"
(cd $work/xfstests && make configure > $out/xfstests-build.log 2>&1 &&
	./configure >> $out/xfstests-build.log 2>&1 &&
	make -C lib >> $out/xfstests-build.log 2>&1 &&
	make -C ltp fsx fsstress >> $out/xfstests-build.log 2>&1)
fsx=$work/xfstests/ltp/fsx
fsstress=$work/xfstests/ltp/fsstress
if [ ! -x $fsx ] || [ ! -x $fsstress ]; then
	note "!! fsx/fsstress did not build"
	tail -20 $out/xfstests-build.log | tee -a $sum
	exit 1
fi

# 当て物の ntfs3 は alma.sh が同じ VM で建てて insmod してある。ここで
# 建て直すと、modprobe -r で外した後に当て済みの木への当て直しで失敗し、
# 出荷の ntfs3 が読み込まれて、それを測っていた (run 40848746640)。
# 建て直さず、読み込まれているのが自分で建てたもの (out-of-tree で
# taint に O が付く) かを確かめる。
drivers=ntfs-3g
for m in ntfs3 ntfs; do
	[ -d /sys/module/$m ] || modprobe $m 2>/dev/null
	[ -d /sys/module/$m ] && drivers="$drivers $m"
done
if [ "${FS_PATCH:-0}" = 1 ]; then
	t=$(cat /sys/module/ntfs3/taint 2>/dev/null)
	note "ntfs3 taint: '$t'"
	case $t in
	*O*) ;;
	*)   note "!! FS_PATCH=1 but the loaded ntfs3 is not the patched build"; exit 1 ;;
	esac
fi
note "ntfs drivers: $drivers"
dmesg -c > /dev/null

# alma.sh の nmount と同じ理由で、カーネルのドライバは mount -i で呼び、
# /proc/mounts の種別を確かめる。
nmount() {	# driver dev
	case $1 in
	ntfs-3g) ntfs-3g $2 /mnt/p; want=fuseblk ;;
	*)       mount -i -t $1 $2 /mnt/p; want=$1 ;;
	esac || return 1
	got=$(awk '$2 == "/mnt/p" { print $3 }' /proc/mounts)
	[ "$got" = "$want" ] || { echo "!! /mnt/p is $got, not $want" >&2; umount /mnt/p; return 1; }
}
# 名前、大きさ、中身の hash。fsstress の作るものは名前も中身も種で決まる。
tree() { (cd /mnt/p && find . -xdev ! -name . -printf '%y %s %p\n' | LC_ALL=C sort &&
	find . -xdev -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum) 2>&1; }

# remount の前後の差を種類ごとに数える。d はディレクトリの行 (大きさ)、
# f/l はファイルの型と大きさ、hash は中身。
kinds() {	# diff of two tree() outputs
	printf 'dir %s, file %s, hash %s' \
		"$(grep -cE '^[<>] d ' "$1")" \
		"$(grep -cE '^[<>] [flcbps] [0-9]' "$1")" \
		"$(grep -cE '^[<>] [0-9a-f]{64} ' "$1")"
}

# 一つの image に一つの負荷。どちらで壊れたかを分けるため。
for drv in $drivers; do
for load in fsx fss; do
	n=stress-$drv-$load
	note ""
	note "### $n"
	raw=$work/$n.raw
	rm -f $raw
	truncate -s 2G $raw
	echo 'type=7' | sfdisk -q $raw
	loop=$(losetup -f -P --show $raw)
	mkntfs -Q -L STRESS ${loop}p1 > $out/$n.mkntfs 2>&1
	if ! nmount $drv ${loop}p1 2> $out/$n.err; then
		note "!! mount failed: $(tail -1 $out/$n.err)"
		losetup -d $loop
		continue
	fi
	case $load in
	fsx)
		# 三つの種で、mmap も含めて。fallocate、punch hole、zero range、
		# collapse/insert range はドライバが受けるかを fsx 自身が確かめる。
		# ntfs-3g は XFS_IOC_EXCHANGE_RANGE の下見を通した後に EINVAL を
		# 返し (EOPNOTSUPP でなく)、fsx はそれを失敗として止まる。
		xo=; [ $drv = ntfs-3g ] && xo=-0
		for seed in 1 2 3; do
			timeout 900 $fsx -q $xo -N 30000 -S $seed -l 8388608 /mnt/p/fsx.$seed \
				> $out/$n.$seed 2>&1
			st=$?
			note "fsx seed $seed: exit $st"
			[ $st = 0 ] || grep -vE '^[0-9]+\(|^ *$' $out/$n.$seed | head -12 | cut -c1-160 | sed 's/^/    /' | tee -a $sum
		done ;;
	fss)
		timeout 900 $fsstress -d /mnt/p/fss -n 4000 -p 4 -s 1 > $out/$n.log 2>&1
		note "fsstress: exit $?" ;;
	esac
	sync
	tree > $out/$n.tree1
	# Windows の chkdsk は file record の番号で言う。ここでは inode 番号が
	# MFT の record 番号なので、win-check.ps1 が path に引き直せるよう残す。
	(cd /mnt/p && find . -xdev -printf '%i %y %s %p\n') > $out/$n.inodes
	umount /mnt/p
	# 大きさ 0 のファイルの $DATA 属性の頭。ntfs3 の fsstress の後、
	# Windows の chkdsk がそういうファイルの $DATA を壊れていると言った。
	# 一行一ファイルで残し、形ごとの数を出す。
	awk '$2 == "f" && $3 == 0 { print $1 }' $out/$n.inodes | while read ino; do
		printf '%s %s\n' $ino "$(ntfsinfo -v -i $ino ${loop}p1 2>/dev/null |
			awk '/Dumping attribute \$DATA/ { p = 1; next }
			     /Dumping attribute/ { p = 0 }
			     p && /Resident|VCN|[Ss]ize|Flags|Compression unit|Mapping pairs/ {
				gsub(/[ \t]+/, " "); printf "%s;", $0 }')"
	done > $out/$n.attrs
	note "zero-size files by \$DATA header: $(wc -l < $out/$n.attrs)"
	cut -d' ' -f2- $out/$n.attrs | sed -E 's/\([^)]*\)//g' | sort | uniq -c | sort -rn | head -6 | cut -c1-220 | sed 's/^/    /' | tee -a $sum
	# 非常駐のものは、属性の record そのものを並べる。比べる相手に、
	# 中身のある一番大きなファイルを一つ足す。
	big=$(sort -k3,3n $out/$n.inodes | awk '$2 == "f" { i = $1 } END { print i }')
	python3 -I $here/mftattr.py ${loop}p1 $(grep 'Resident: No' $out/$n.attrs | cut -d' ' -f1) $big > $out/$n.rawattrs
	note "empty non-resident \$DATA with runs left behind: $(grep -c STALE-RUNS $out/$n.rawattrs) (expect 0)"
	head -4 $out/$n.rawattrs | cut -c1-400 | sed 's/^/    $DATA /' | tee -a $sum
	if nmount $drv ${loop}p1 2>> $out/$n.err; then
		tree > $out/$n.tree2
		umount /mnt/p
		diff $out/$n.tree1 $out/$n.tree2 | grep '^[<>]' > $out/$n.treediff
		note "after remount: differing lines $(wc -l < $out/$n.treediff) of $(wc -l < $out/$n.tree1) ($(kinds $out/$n.treediff))"
		grep -vE '^[<>] d ' $out/$n.treediff | head -6 | cut -c1-160 | tee -a $sum
		# ディレクトリの大きさは前後を並べる (path: 前 -> 後、子の数)。
		awk '$1 == "d" { print $3, $2 }' $out/$n.tree1 | sort > $out/$n.d1
		awk '$1 == "d" { print $3, $2 }' $out/$n.tree2 | sort > $out/$n.d2
		join $out/$n.d1 $out/$n.d2 | awk '$2 != $3' | head -6 | while read d a b; do
			printf '    %s: %s -> %s (%s entries)\n' "$d" $a $b \
				"$(grep -c "^. [0-9]* $d/[^/]*\$" $out/$n.tree1)"
		done | tee -a $sum
	else
		note "!! remount failed: $(tail -1 $out/$n.err)"
	fi
	ntfsfix -n ${loop}p1 > $out/$n.ntfsfix 2>&1
	note "ntfsfix -n exit $?"
	dmesg -c > $out/$n.dmesg
	note "dmesg: $(grep -ciE 'warning|bug|error|corrupt|oops|call trace' $out/$n.dmesg) suspicious lines"
	grep -iE 'warning|bug|error|corrupt|oops|call trace' $out/$n.dmesg | head -8 | cut -c1-200 | sed 's/^/    /' | tee -a $sum
	losetup -d $loop
	qemu-img convert -f raw -O vpc -o subformat=fixed,force_size=on $raw $out/$n.vhd
	rm -f $raw
done
done
