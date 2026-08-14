#!/bin/sh
# 配布セットからブート可能な NetBSD のディスクイメージを組む。
#
#   root で:  sh mkimg.sh <arch> <release>
#   例:       sh mkimg.sh i386 10.1
#             sh mkimg.sh sparc64 11.0
#             sh mkimg.sh i386 7.2
#
# NetBSD の上でしか動かない。vnconfig / disklabel / newfs / installboot が
# 要るため。GitHub Actions の runner は Linux なのでここでは組めず、出来た
# イメージを持っていって QEMU で回す。
#
# 公式に置いてあるのはインストーラ (ISO と install.img) だけで、インストール
# 済みのイメージは無い。sysinst に無人インストールの仕組みも無いので、セット
# を直接展開して作るこの方法が一番手数が少ない。
#
# 中身は素の NetBSD。特定の用途に寄せた細工はしていない。sshd を上げて root
# の鍵を置いてあるだけなので、何を組むのにも使える。
#
# 出来上がりは <arch>-<release>.img.gz。
#
# 環境変数で変えられるもの:
#   BASE      作業場所 (既定 $HOME/nbimg)
#   X_SETS    入れる X のセット。要らなければ X_SETS= で空に
#   ROOTDEV   fstab に書く root デバイス。QEMU の繋ぎ方で決まる
#   SECT      イメージの総セクタ数

set -e

ARCH=$1
REL=$2
[ -n "$ARCH" ] && [ -n "$REL" ] || { echo "usage: $0 <arch> <release>"; exit 1; }

BASE=${BASE:-$HOME/nbimg}
SETS=$BASE/sets/$ARCH-$REL
MNT=${MNT:-/mnt/nbimg}
VND=${VND:-vnd3}
IMG=$BASE/$ARCH-$REL.img
SECT=${SECT:-25165824}		# 12 GiB。sparse なので実際に食うのは展開したぶんだけ

# 9.0 より前は本ミラーから外れて archive にある。
MAJOR=${REL%%.*}
if [ "$MAJOR" -ge 9 ] 2>/dev/null; then
	MIRROR=http://cdn.netbsd.org/pub/NetBSD/NetBSD-$REL
else
	MIRROR=http://archive.netbsd.org/pub/NetBSD-archive/NetBSD-$REL
fi

# FFSv2 は NetBSD 2.0 から。古いものは v1 でないとカーネルが読めない。
if [ "$MAJOR" -ge 5 ] 2>/dev/null; then
	FFS=2
else
	FFS=1
fi

# ブートのしかたはアーキテクチャで違う。
#
#   i386/amd64  MBR を掘り、その中に disklabel を置く。ラベルを書く相手は
#               ディスク全体 (d)。二次ブートの bootxx を FFS のブート域に、
#               一次ブートの mbr を MBR に、それぞれ別に書く。
#   sparc64     MBR を使わず disklabel だけ。ラベルの相手は c。bootblk が
#               パーティションのセクタ 1 に入る。
#
# root デバイス名は QEMU の繋ぎ方で決まり、fstab と食い違うと起動しない。
#
#   if=virtio -> ld0     virtio は NetBSD 6.0 から。5.x 以下には無い
#   if=ide    -> wd0     どの版でも通る
#
# 同じ理由で NIC も選ぶ。vioif は 6.0 から、wm (e1000) も古い版には無いので、
# 5.x 以下は ne2k_pci にしておく。組み合わせは .qemu に書き出すので、動かす
# 側はそれを読めばよい。
case $ARCH in
i386|amd64)
	USE_MBR=yes; LABELDEV=d; BOOTXX=bootxx_ffsv$FFS
	if [ "$MAJOR" -ge 6 ] 2>/dev/null; then
		DISKIF=virtio; NICDEV=virtio-net-pci; ROOTDEV=${ROOTDEV:-ld0a}
	else
		DISKIF=ide;    NICDEV=ne2k_pci;       ROOTDEV=${ROOTDEV:-wd0a}
	fi ;;
sparc64)
	USE_MBR=no;  LABELDEV=c; BOOTXX=bootblk
	DISKIF=ide;  NICDEV=;    ROOTDEV=${ROOTDEV:-wd0a} ;;
*)
	echo "$0: $ARCH は未対応 (MBR とブートローダの扱いを足すこと)"; exit 1 ;;
esac

echo "=== NetBSD $REL / $ARCH ==="
echo "    ミラー   $MIRROR"
echo "    FFSv$FFS / MBR=$USE_MBR / $BOOTXX"
echo "    disk=$DISKIF root=$ROOTDEV nic=${NICDEV:-(既定)}"

# ------------------------------------------------------------------
echo "--- セットを取る ---"
mkdir -p $SETS
# X は base の x セットから入る。pkgsrc の x11-links がここを指すので、
# X を使うものを組むなら入れておかないと話が始まらない。Xvfb もここ。
X_SETS=${X_SETS-"xbase xcomp xetc xfont xserver"}
for s in base etc comp text; do
	[ -s $SETS/$s.tgz ] || ftp -o $SETS/$s.tgz \
		$MIRROR/$ARCH/binary/sets/$s.tgz
done
# X は無いアーキテクチャ・版があるので、取れなければ黙って飛ばす。
for s in $X_SETS; do
	[ -s $SETS/$s.tgz ] && continue
	ftp -o $SETS/$s.tgz $MIRROR/$ARCH/binary/sets/$s.tgz 2>/dev/null || {
		echo "    ($s は無い)"; rm -f $SETS/$s.tgz; }
done
# カーネルの置き場と綴りは版によって違う。1.6 以降は netbsd-GENERIC.gz、
# 1.5 以前は netbsd.GENERIC.gz (中黒ではなく点)、版によってはセットの
# kern-GENERIC.tgz に入っているだけのこともある。
if [ ! -s $SETS/netbsd-GENERIC.gz ] && [ ! -s $SETS/kern-GENERIC.tgz ]; then
	ftp -o $SETS/netbsd-GENERIC.gz \
		$MIRROR/$ARCH/binary/kernel/netbsd-GENERIC.gz 2>/dev/null || \
	ftp -o $SETS/netbsd-GENERIC.gz \
		$MIRROR/$ARCH/binary/kernel/netbsd.GENERIC.gz 2>/dev/null || \
	ftp -o $SETS/kern-GENERIC.tgz \
		$MIRROR/$ARCH/binary/sets/kern-GENERIC.tgz
	[ -s $SETS/netbsd-GENERIC.gz ] || [ -s $SETS/kern-GENERIC.tgz ] || \
		{ echo "$0: カーネルが見つからない"; exit 1; }
fi

# ------------------------------------------------------------------
echo "--- イメージを作る ---"
umount $MNT 2>/dev/null || true
vnconfig -u $VND 2>/dev/null || true
rm -f $IMG $IMG.gz
mkdir -p $MNT $BASE
dd if=/dev/zero of=$IMG bs=512 count=1 seek=$((SECT - 1)) 2>/dev/null
vnconfig -c $VND $IMG

if [ $USE_MBR = yes ]; then
	START=63
	PSIZE=$((SECT - START))
	echo "--- MBR (169 = NetBSD) ---"
	fdisk -f -u -0 -s 169/$START/$PSIZE -a /dev/r${VND}d > /dev/null
else
	START=0
	PSIZE=$SECT
fi

echo "--- disklabel ---"
cat > /tmp/nbimg.label <<LBL
type: ESDI
disk: nbimg
label: nbimg
flags:
bytes/sector: 512
sectors/track: 63
tracks/cylinder: 16
sectors/cylinder: 1008
cylinders: $((SECT / 1008))
total sectors: $SECT
rpm: 3600
interleave: 1
trackskew: 0
cylinderskew: 0
headswitch: 0
track-to-track seek: 0
drivedata: 0

4 partitions:
#        size    offset     fstype [fsize bsize cpg/sgs]
 a:  $PSIZE  $START     4.2BSD   1024  8192    0
 c:  $PSIZE  $START     unused      0     0
 d:  $SECT         0     unused      0     0
LBL
disklabel -R -r /dev/r${VND}$LABELDEV /tmp/nbimg.label

echo "--- newfs (FFSv$FFS) ---"
newfs -O $FFS /dev/r${VND}a > /dev/null

echo "--- セット展開 ---"
mount /dev/${VND}a $MNT
for s in base etc comp text $X_SETS; do
	[ -s $SETS/$s.tgz ] || continue
	echo "    $s"
	tar -xpzf $SETS/$s.tgz -C $MNT
done

echo "--- カーネル ---"
if [ -s $SETS/netbsd-GENERIC.gz ]; then
	zcat $SETS/netbsd-GENERIC.gz > $MNT/netbsd
else
	tar -xpzf $SETS/kern-GENERIC.tgz -C $MNT
fi
chmod 644 $MNT/netbsd

echo "--- 設定 ---"
cat > $MNT/etc/fstab <<FST
/dev/$ROOTDEV	/	ffs	rw	1 1
ptyfs		/dev/pts	ptyfs	rw	0 0
kernfs		/kern	kernfs	rw	0 0
procfs		/proc	procfs	rw	0 0
FST

# dhcpcd が既定になったのは NetBSD 6 から。それ以前は dhclient。
# 知らない項目は無視されるので両方書いておく。
cat > $MNT/etc/rc.conf <<RCC
rc_configured=YES
hostname=nbimg-$ARCH-$REL
sshd=YES
dhcpcd=YES
dhclient=YES
no_swap=YES
RCC

mkdir -p $MNT/root/.ssh
if [ -s $BASE/authorized_keys ]; then
	cat $BASE/authorized_keys > $MNT/root/.ssh/authorized_keys
elif [ -s $HOME/.ssh/id_rsa.pub ]; then
	cat $HOME/.ssh/id_rsa.pub > $MNT/root/.ssh/authorized_keys
else
	echo "!! 公開鍵が無い。$BASE/authorized_keys に置くこと" >&2
fi
chmod 700 $MNT/root/.ssh
chmod 600 $MNT/root/.ssh/authorized_keys
echo 'PermitRootLogin prohibit-password' >> $MNT/etc/ssh/sshd_config

mkdir -p $MNT/kern $MNT/proc $MNT/dev/pts
( cd $MNT/dev && sh MAKEDEV all ) > /dev/null 2>&1 || echo "    (MAKEDEV 省略)"

echo "--- ブートローダ ---"
# installboot と fdisk -c は生デバイスに書く。sparc64 の bootblk は
# パーティションのセクタ 1 に入るため、マウントしたままだとカーネルに
# 拒まれて "Read-only file system" になる。要るものを先に取り出して
# umount してから書けば、どのアーキテクチャでも同じ手順で済む。
cp $MNT/usr/mdec/$BOOTXX /tmp/$BOOTXX
if [ $USE_MBR = yes ]; then
	cp $MNT/usr/mdec/mbr /tmp/mbr
	cp $MNT/usr/mdec/boot $MNT/boot
else
	cp $MNT/usr/mdec/ofwboot $MNT/ofwboot
fi

df -h $MNT | tail -1
umount $MNT

installboot -v -m $ARCH /dev/r${VND}a /tmp/$BOOTXX
# 一次ブート。&& でつなぐと sparc64 のとき偽になり set -e で落ちるので if で。
if [ $USE_MBR = yes ]; then
	fdisk -f -c /tmp/mbr /dev/r${VND}d > /dev/null
fi

vnconfig -u $VND

# 動かす側がイメージを見ただけでは繋ぎ方が分からないので、添えておく。
# 食い違うと root が見つからず起動しない。
cat > $BASE/$ARCH-$REL.qemu <<META
ARCH=$ARCH
RELEASE=$REL
QEMU=qemu-system-$(case $ARCH in amd64) echo x86_64 ;; *) echo $ARCH ;; esac)
DISKIF=$DISKIF
NICDEV=$NICDEV
ROOTDEV=$ROOTDEV
META
echo "--- 繋ぎ方 ($BASE/$ARCH-$REL.qemu) ---"
cat $BASE/$ARCH-$REL.qemu

echo "--- 圧縮 ---"
gzip -9 $IMG
ls -l $IMG.gz
echo "OK: $IMG.gz"
