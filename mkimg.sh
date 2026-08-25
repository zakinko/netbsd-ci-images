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
#   BASE      作業場所 (既定はこのスクリプトの置き場)
#   PROFILE   出来上がりの使い道。qemu (既定) か vultr
#   X_SETS    入れる X のセット。要らなければ X_SETS= で空に
#   ROOTDEV   fstab に書く root デバイス。QEMU の繋ぎ方で決まる
#   SECT      イメージの総セクタ数

set -e

ARCH=$1
REL=$2
[ -n "$ARCH" ] && [ -n "$REL" ] || { echo "usage: $0 <arch> <release>"; exit 1; }

# 既定はこのスクリプトの置き場。$HOME にすると su や sudo で走らせたときに
# /root を指し、鍵もセットも別の場所を見にいく。
BASE=${BASE:-$(cd "$(dirname "$0")" && pwd)}
SETS=$BASE/sets/$ARCH-$REL
MNT=${MNT:-/mnt/nbimg}
VND=${VND:-vnd3}
# 出来上がりの使い道。qemu は CI で QEMU に食わせるいつもの版、vultr は
# Vultr の snapshot-from-URL に渡して VPS のディスクへ書く版。
#
# 分けているのは向こうの都合が三つあるため。
#
#   - Vultr は raw しか受け取らない。gz も qcow2 も通らないので、置き場を
#     GitHub の release にすると asset 一つ 2GiB の上限に当たる。全セット
#     入り 12GiB のままでは載らないので、X を落として 1.75GiB に切り詰める
#   - Vultr にシリアルは出ていない。見えるのは VGA を noVNC で覗く web
#     console だけで、consdev=com0 にすると起動しなかったときに何も残らない
#   - 一番安い vc2-1c-0.5gb-v6 には IPv4 が付かない。住所は RA で降ってくる
#     ので、dhcpcd を上げるだけでは足りない
#
# ディスクは virtio-blk で見える。NetBSD からは ld0 で、10 以降の QEMU 側の
# 既定にしている virtio-scsi (sd0) とは名前が違う。fstab と食い違うと root が
# 見つからずに止まる。
PROFILE=${PROFILE:-qemu}
case $PROFILE in
qemu)	NAME=$ARCH-$REL
	DEFSECT=25165824 ;;	# 12 GiB。sparse なので実際に食うのは展開したぶんだけ
vultr)	NAME=$ARCH-$REL-vultr
	DEFSECT=3670016		# 1.75 GiB。release の asset 一つ 2GiB に収める
	ROOTDEV=${ROOTDEV:-ld0a} ;;
*)	echo "$0: PROFILE=$PROFILE は知らない (qemu か vultr)" >&2; exit 1 ;;
esac
IMG=$BASE/$NAME.img
SECT=${SECT:-$DEFSECT}

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
#   virtio-scsi -> sd0   vioscsi は NetBSD 10 から
#   virtio      -> ld0   virtio-blk。6.0 から。5.x 以下には無い
#   ide         -> wd0   どの版でも通る
#
# 同じ理由で NIC も選ぶ。vioif は 6.0 から、wm (e1000) も古い版には無いので、
# 5.x 以下は ne2k_pci にしておく。組み合わせは .qemu に書き出すので、動かす
# 側はそれを読めばよい。
case $ARCH in
i386|amd64)
	USE_MBR=yes; LABELDEV=d; BOOTXX=bootxx_ffsv$FFS
	if [ "$MAJOR" -ge 10 ] 2>/dev/null; then
		DISKIF=virtio-scsi; NICDEV=virtio-net-pci; ROOTDEV=${ROOTDEV:-sd0a}
	elif [ "$MAJOR" -ge 6 ] 2>/dev/null; then
		DISKIF=virtio;      NICDEV=virtio-net-pci; ROOTDEV=${ROOTDEV:-ld0a}
	else
		DISKIF=ide;         NICDEV=ne2k_pci;       ROOTDEV=${ROOTDEV:-wd0a}
	fi ;;
sparc64)
	USE_MBR=no;  LABELDEV=c; BOOTXX=bootblk
	DISKIF=ide;  NICDEV=;    ROOTDEV=${ROOTDEV:-wd0a} ;;
*)
	echo "$0: $ARCH は未対応 (MBR とブートローダの扱いを足すこと)"; exit 1 ;;
esac

# Vultr が繋ぐのは virtio-blk と virtio-net。10 以降の既定 (virtio-scsi) の
# ままだと .qemu の中身が実物と食い違い、手元で試し起動したときだけ通って
# 本番で root が見つからない、という一番たちの悪い転け方をする。
if [ $PROFILE = vultr ]; then
	[ $USE_MBR = yes ] || { echo "$0: PROFILE=vultr は x86 のみ" >&2; exit 1; }
	DISKIF=virtio
	NICDEV=virtio-net-pci
fi

# virtio-scsi は -drive if=... では繋がらない。コントローラと scsi-hd を
# 別々に並べる必要があるので、インタフェース名ではなくディスク指定の全体を
# 持たせる。@IMG@ は動かす側がイメージのパスに置き換える。
#
# cache=unsafe は guest の flush を無視してホストの page cache に載せたまま
# にする。インタフェースを選び直すより桁違いに効く。使い捨ての CI イメージ
# 前提なので、ホストごと落ちて壊れても gz から展開し直せば済む。手を入れた
# まま残したいイメージには使わないこと。
# aio=native は cache.direct=on を要求するので unsafe とは併用できない。
# 既定の threads のままにしてある。
DOPT="format=raw,cache=unsafe,discard=unmap"
case $DISKIF in
virtio-scsi)
	DISKARGS="-device virtio-scsi-pci,id=scsi0 -drive file=@IMG@,if=none,id=d0,$DOPT -device scsi-hd,drive=d0,bus=scsi0.0" ;;
*)
	DISKARGS="-drive file=@IMG@,if=$DISKIF,$DOPT" ;;
esac

# 鍵はここで確かめる。無いまま進むと、セットを落として展開し終えてから
# ログインできないイメージが出来上がるだけで、誰の得にもならない。
if [ -s "$BASE/authorized_keys" ]; then
	PUBKEY=$BASE/authorized_keys
elif [ -s "$HOME/.ssh/id_rsa.pub" ]; then
	PUBKEY=$HOME/.ssh/id_rsa.pub
else
	echo "$0: 公開鍵が無い。$BASE/authorized_keys に置くこと" >&2
	echo "    (BASE=$BASE。su や sudo で HOME が変わっている場合は" >&2
	echo "     BASE=... を明示するか、スクリプトと同じ場所に置く)" >&2
	exit 1
fi

echo "=== NetBSD $REL / $ARCH ==="
echo "    ミラー   $MIRROR"
echo "    鍵       $PUBKEY"
echo "    FFSv$FFS / MBR=$USE_MBR / $BOOTXX"
echo "    disk=$DISKIF root=$ROOTDEV nic=${NICDEV:-(既定)}"

# ------------------------------------------------------------------
echo "--- セットを取る ---"
mkdir -p $SETS
# X は base の x セットから入る。pkgsrc の x11-links がここを指すので、
# X を使うものを組むなら入れておかないと話が始まらない。Xvfb もここ。
# vultr は 1.75GiB に収めるのが先で、X の五セットは入り切らない。
if [ $PROFILE = vultr ]; then
	X_SETS=${X_SETS-}
else
	X_SETS=${X_SETS-"xbase xcomp xetc xfont xserver"}
fi
# セットの綴りは port と版で割れている。i386 は今も .tgz だが、amd64 と
# sparc64 は .tar.xz になっており、10.1 でも port によって違う。どちらが
# 置いてあるかはミラーを叩くまで分からないので順に試す。展開する tar は
# libarchive なので、-z を外して見分けを任せればどちらも読める。
SETEXT="tgz tar.xz"

setfile() {	# 取ってあるセットの実体を書き出す。無ければ 1 を返す
	for _x in $SETEXT; do
		[ -s "$SETS/$1.$_x" ] && { echo "$SETS/$1.$_x"; return 0; }
	done
	return 1
}

fetchset() {	# 取ってなければ取る。どちらの綴りも無ければ 1 を返す
	setfile "$1" > /dev/null && return 0
	for _x in $SETEXT; do
		ftp -o "$SETS/$1.$_x" "$MIRROR/$ARCH/binary/sets/$1.$_x" \
			2>/dev/null && return 0
		rm -f "$SETS/$1.$_x"
	done
	return 1
}

for s in base etc comp text; do
	fetchset $s || { echo "$0: $s が取れない ($MIRROR)" >&2; exit 1; }
done
# X は無いアーキテクチャ・版があるので、取れなければ黙って飛ばす。
for s in $X_SETS; do
	fetchset $s || echo "    ($s は無い)"
done
# カーネルの置き場と綴りは版によって違う。1.6 以降は netbsd-GENERIC.gz、
# 1.5 以前は netbsd.GENERIC.gz (中黒ではなく点)、版によってはセットの
# kern-GENERIC.tgz に入っているだけのこともある。
if [ ! -s $SETS/netbsd-GENERIC.gz ] && ! setfile kern-GENERIC > /dev/null; then
	ftp -o $SETS/netbsd-GENERIC.gz \
		$MIRROR/$ARCH/binary/kernel/netbsd-GENERIC.gz 2>/dev/null || \
	ftp -o $SETS/netbsd-GENERIC.gz \
		$MIRROR/$ARCH/binary/kernel/netbsd.GENERIC.gz 2>/dev/null || \
	fetchset kern-GENERIC
	[ -s $SETS/netbsd-GENERIC.gz ] || setfile kern-GENERIC > /dev/null || \
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
# ラベルの中身は作るイメージのアーキテクチャで決まるが、書き込み先の
# デバイスノードは走らせているホストの規約で決まる。i386 のホストでは
# ディスク全体が d で、c は MBR 内の NetBSD 領域を指すため、MBR を掘らない
# 構成では c が存在せず "Device not configured" になる。どちらが通るかは
# ホスト次第なので試す。
LABELOK=
for _d in $LABELDEV d c; do
	[ -c /dev/r${VND}$_d ] || continue
	if disklabel -R -r /dev/r${VND}$_d /tmp/nbimg.label 2> /tmp/nbimg.dlerr; then
		LABELOK=$_d
		echo "    (/dev/r${VND}$_d に書いた)"
		break
	fi
done
if [ -z "$LABELOK" ]; then
	echo "$0: disklabel を書けない:" >&2
	cat /tmp/nbimg.dlerr >&2
	ls -l /dev/r${VND}? >&2
	exit 1
fi

echo "--- newfs (FFSv$FFS) ---"
newfs -O $FFS /dev/r${VND}a > /dev/null

echo "--- セット展開 ---"
mount /dev/${VND}a $MNT
for s in base etc comp text $X_SETS; do
	f=$(setfile $s) || continue
	echo "    $s"
	tar -xpf $f -C $MNT
done

echo "--- カーネル ---"
if [ -s $SETS/netbsd-GENERIC.gz ]; then
	zcat $SETS/netbsd-GENERIC.gz > $MNT/netbsd
else
	tar -xpf "$(setfile kern-GENERIC)" -C $MNT
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
# 既定を読む行を先に置く。NetBSD の /etc/rc.conf は冒頭で
# /etc/defaults/rc.conf を source する作りで、丸ごと上書きするとその行ごと
# 消える。既定が一つも入らないので、rc.subr が全サービスについて
# "$foo is not set properly - see rc.conf(5)" を吐き、起動のたびに十数行
# 流れる。起動そのものは通るので今まで見過ごしていた。
cat > $MNT/etc/rc.conf <<RCC
if [ -r /etc/defaults/rc.conf ]; then
	. /etc/defaults/rc.conf
fi

rc_configured=YES
hostname=nbimg-$ARCH-$REL
sshd=YES
dhcpcd=YES
dhclient=YES
no_swap=YES
RCC

# Vultr の一番安い plan には IPv4 が付かず、住所は RA で降ってくる。RA を
# 受け取るかどうかは ip6mode で決まるので、dhcpcd を上げてあっても既定の
# host のままでは住所が付かないまま上がってしまう。
if [ $PROFILE = vultr ]; then
	cat >> $MNT/etc/rc.conf <<RCC
ip6mode=autohost
rtsol=YES
RCC
fi

# コンソールをシリアルに出す。既定の VGA のままだと QEMU を -display none
# で回したときに何も残らず、起動しなかったときに画面を撮るしか手が無い。
# CI では読めるログが要る。
#
# boot.cfg は NetBSD 5.0 から。それ以前のブートローダは読まないので、
# カーネルのメッセージは VGA のままになる。getty だけは効く。
if [ $USE_MBR = yes ] && [ "$MAJOR" -ge 5 ] 2>/dev/null; then
	if [ $PROFILE = vultr ]; then
		# Vultr にシリアルは無い。見えるのは VGA を覗く web console
		# だけなので、consdev は既定のまま置く。動かすと起動しなかった
		# ときに読むものが何も残らない。
		cat > $MNT/boot.cfg <<BCFG
menu=Boot normally:boot
default=1
timeout=2
BCFG
	else
		cat > $MNT/boot.cfg <<BCFG
menu=Boot normally:consdev com0;boot
default=1
timeout=2
consdev=com0
BCFG
	fi
fi
# シリアルに getty を出す。sparc64 は OpenBIOS が既にシリアルなので、
# どちらの場合も ttys の該当行を on にしておけばよい。
if [ -f $MNT/etc/ttys ]; then
	sed -e 's|^\(console.*\)off\(.*\)|\1on \2|' \
	    -e 's|^\(tty00\).*|\1	"/usr/libexec/getty std.9600"	vt100	on secure|' \
		$MNT/etc/ttys > $MNT/etc/ttys.new && mv $MNT/etc/ttys.new $MNT/etc/ttys
fi

mkdir -p $MNT/root/.ssh
cat $PUBKEY > $MNT/root/.ssh/authorized_keys
chmod 700 $MNT/root/.ssh
chmod 600 $MNT/root/.ssh/authorized_keys
echo 'PermitRootLogin prohibit-password' >> $MNT/etc/ssh/sshd_config

mkdir -p $MNT/kern $MNT/proc $MNT/dev/pts
( cd $MNT/dev && sh MAKEDEV all ) > /dev/null 2>&1 || echo "    (MAKEDEV 省略)"

echo "--- ブートローダ ---"
# installboot と fdisk -c は生デバイスに書くので、先に要るものを取り出して
# から umount する。
cp $MNT/usr/mdec/$BOOTXX /tmp/$BOOTXX
if [ $USE_MBR = yes ]; then
	cp $MNT/usr/mdec/mbr /tmp/mbr
	cp $MNT/usr/mdec/boot $MNT/boot
else
	cp $MNT/usr/mdec/ofwboot $MNT/ofwboot
fi

df -h $MNT | tail -1
umount $MNT

# 書き込み先。a が sector 0 から始まる構成 (sparc64) では、bootblk の入る
# sector 1 が disklabel の保護領域に掛かり、カーネルが EROFS で拒む。
# "installboot: Writing `/dev/rvnd?a': Read-only file system" がそれで、
# umount しても消えない。ホストの raw partition 経由なら保護されず、a の
# offset が 0 なので指す先は同じになる。i386/amd64 は a が MBR 内の sector
# 63 から始まりラベルを含まないので、そのまま a に書ける。
if [ $USE_MBR = yes ]; then
	BOOTDEV=/dev/r${VND}a
else
	BOOTDEV=/dev/r${VND}$LABELOK
fi
if ! installboot -v -m $ARCH $BOOTDEV /tmp/$BOOTXX; then
	echo "$0: installboot が失敗した ($BOOTDEV)" >&2
	exit 1
fi

# 一次ブート。&& でつなぐと sparc64 のとき偽になり set -e で落ちるので if で。
if [ $USE_MBR = yes ]; then
	fdisk -f -c /tmp/mbr /dev/r${VND}d > /dev/null
fi

vnconfig -u $VND

# 動かす側がイメージを見ただけでは繋ぎ方が分からないので、添えておく。
# 食い違うと root が見つからず起動しない。
cat > $BASE/$NAME.qemu <<META
ARCH=$ARCH
RELEASE=$REL
QEMU=qemu-system-$(case $ARCH in amd64) echo x86_64 ;; *) echo $ARCH ;; esac)
DISKIF=$DISKIF
DISKARGS="$DISKARGS"
NICDEV=$NICDEV
ROOTDEV=$ROOTDEV
META
echo "--- 繋ぎ方 ($BASE/$NAME.qemu) ---"
cat $BASE/$NAME.qemu

# Vultr の snapshot-from-URL は raw しか受け取らないので、vultr の版は
# 固めない。公開 URL にこのまま置く。
if [ $PROFILE = vultr ]; then
	ls -l $IMG
	echo "OK: $IMG (raw のまま。公開 URL に置いて vultr/up.yml に渡す)"
else
	echo "--- 圧縮 ---"
	gzip -9 $IMG
	ls -l $IMG.gz
	echo "OK: $IMG.gz"
fi
