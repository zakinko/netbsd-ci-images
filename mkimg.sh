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
#   PROFILE   出来上がりの使い道。qemu (既定)、vultr、sakura
#   X_SETS    入れる X のセット。要らなければ X_SETS= で空に
#   ROOTDEV   fstab に書く root デバイス。QEMU の繋ぎ方で決まる
#   SECT      イメージの総セクタ数
#   IMGHOST   焼くホスト名 (既定は nbimg-<arch>-<release>)。HOSTNAME という
#             名前にしない。bash は自分でその変数を設定するので、sh のつもりで
#             bash に読ませた瞬間、焼く側の箱の名前が黙って入る
#   NETIF     静的な住所を付ける口 (既定 vioif0)
#   IPV4      静的に焼く住所。<addr>/<prefixlen>。空なら dhcpcd に任せる
#   GATEWAY   既定経路。IPV4 を渡したときだけ見る
#   IPV6      静的に焼く v6 の住所。<addr>/<prefixlen>
#   GATEWAY6  v6 の既定経路。link-local なら %<if> まで書く (fe80::1%vioif0)
#   DNS       resolv.conf に書く nameserver。空白区切り。v4 も v6 も書ける
#   CONSDEV   コンソール。com0 か pc。既定は PROFILE ごと
#   SWAPDEV   fstab に書く swap (例 ld0b)。空なら swap 無しで上げる
#
# 住所やホスト名をここに書かないのは、この repo が public なため。焼く側が
# 渡す。

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
# sakura は「既に走っている箱のディスクへ、自力で dd して入れ替える」版。
# さくらの VPS には Vultr のような「URL から snapshot を作る」口が無いので、
# 焼いたイメージを一旦 swap の領域に置き、そこから先頭へ書き戻す。向こうの
# 都合は二つ。
#
#   - DHCP を配っていない。住所は契約で決まった静的なものなので、焼く前に
#     入れておかないと、上がっても誰も繋げない
#   - コンソールはシリアル。今 techne が com0 で上がっているのがその証拠で、
#     consdev はそちらに向けておく
#
# 置き場の 2GiB 制限は掛からないが、大きさは swap に収まることと、書き戻す
# 時間の短さで決まる。vultr と同じ 1.75GiB にしてある。起動してからディスク
# 一杯に広げる。
#
# ディスクは virtio-blk で見える。NetBSD からは ld0 で、10 以降の QEMU 側の
# 既定にしている virtio-scsi (sd0) とは名前が違う。fstab と食い違うと root が
# 見つからずに止まる。
PROFILE=${PROFILE:-qemu}
case $PROFILE in
qemu)	NAME=$ARCH-$REL
	DEFSECT=25165824	# 12 GiB。sparse なので実際に食うのは展開したぶんだけ
	CONSDEV=${CONSDEV:-com0} ;;
vultr)	NAME=$ARCH-$REL-vultr
	DEFSECT=3670016		# 1.75 GiB。release の asset 一つ 2GiB に収める
	ROOTDEV=${ROOTDEV:-ld0a}
	CONSDEV=${CONSDEV:-pc} ;;
sakura)	NAME=$ARCH-$REL-sakura
	DEFSECT=3670016		# 1.75 GiB。swap に置いてから先頭へ書き戻す
	ROOTDEV=${ROOTDEV:-ld0a}
	CONSDEV=${CONSDEV:-com0} ;;
*)	echo "$0: PROFILE=$PROFILE は知らない (qemu, vultr, sakura)" >&2; exit 1 ;;
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

# vultr と sakura は「本物の VPS のディスクに書く」版で、X を落とすところ、
# raw で置くところ、virtio-blk で繋ぐところが同じ。片方だけ直す事故を避けたい
# ので、判定を一つにまとめておく。
case $PROFILE in
vultr|sakura)	VPS=yes ;;
*)		VPS=no ;;
esac

# どちらの VPS も繋ぐのは virtio-blk と virtio-net。10 以降の既定
# (virtio-scsi) のままだと .qemu の中身が実物と食い違い、手元で試し起動した
# ときだけ通って本番で root が見つからない、という一番たちの悪い転け方をする。
if [ $VPS = yes ]; then
	[ $USE_MBR = yes ] ||
		{ echo "$0: PROFILE=$PROFILE は x86 のみ" >&2; exit 1; }
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
# VPS 向けは 1.75GiB に収めるのが先で、X の五セットは入り切らない。
if [ $VPS = yes ]; then
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
# rescue は別セット。base には入っていない。
#
# 無いと toor が壊れる。NetBSD が配る master.passwd の toor は shell が
# /rescue/sh で、これはそのセットに入っている。今まで焼いたイメージは
# どれも「shell の無い toor」を持っていた。toor はロックされているので
# 表に出なかったが、パスワードを付けた途端に入れなくなる。
#
# それとは別に、静的リンクの一式が入っていること自体に価値がある。
# /usr や /usr/pkg が壊れても、そこから入って直せる。コンソールに
# 逃げられない箱ではなおさら。8 MB ほどしか食わない。
#
# 古い版には無いので、取れなければ黙って飛ばす。
RESCUE_SET=rescue
fetchset $RESCUE_SET || { echo "    (rescue は無い)"; RESCUE_SET=; }
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
for s in base etc comp text $RESCUE_SET $X_SETS; do
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

# swap は焼く側が知っている。QEMU で回すぶんには要らないが、実機に書く版で
# 無いままだと 2GB の箱がそのまま 2GB で回ることになる。
if [ -n "${SWAPDEV-}" ]; then
	echo "/dev/$SWAPDEV	none	swap	sw	0 0" >> $MNT/etc/fstab
fi

# ホスト名の点は潰す。版の番号をそのまま入れると nbimg-amd64-10.1 になり、
# 点を含む名前は FQDN と解釈されてドメイン部が "1" になる。postfix は数字
# だけのドメインを不正として mydomain の設定に失敗し、起動に転ける。
# rc.conf が既定を読んでいなかった間は postfix がそもそも起動対象にならず、
# この壊れは隠れていた。
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
hostname=${IMGHOST:-nbimg-$ARCH-$(echo $REL | tr . -)}
sshd=YES
RCC

# 住所の付け方。IPV4 を渡されたら静的に焼いて dhcpcd は上げない。DHCP を
# 配っていない相手 (さくらの VPS がそう) では、これが無いと上がっても誰も
# 繋げない。dd で入れ替える版はコンソールに逃げられないので、ここを外すと
# 箱ごと失う。
if [ -n "${IPV4-}" ]; then
	cat >> $MNT/etc/rc.conf <<RCC
dhcpcd=NO
RCC
	cat > $MNT/etc/ifconfig.${NETIF:-vioif0} <<IFC
up
inet $IPV4
IFC
	# v6 も静的に焼く。さくらは /64 を一つ割り当てるが、台帳に載る住所は
	# IPv4 を埋め込んだもの (…:49:212:144:112) で、MAC から作る SLAAC の
	# 住所とは一致しない。RA を受けても DNS の AAAA と食い違うので、
	# ip6mode は既定の host のまま、住所は書いて渡す。
	if [ -n "${IPV6-}" ]; then
		echo "inet6 $IPV6" >> $MNT/etc/ifconfig.${NETIF:-vioif0}
	fi
	# set -e の下では && で繋ぐと、条件が偽になった時点で script ごと
	# 落ちる。GATEWAY を渡さない使い方があるので if で書く。
	if [ -n "${GATEWAY-}" ]; then
		echo "$GATEWAY" > $MNT/etc/mygate
	fi
	# v6 の既定経路は rc.conf 側。空なら /etc/mygate6 が読まれる。
	# さくらのゲートウェイは fe80::1 で、link-local は scope が無いと
	# route が付かないので %<if> まで要る。
	if [ -n "${GATEWAY6-}" ]; then
		cat >> $MNT/etc/rc.conf <<RCC
defaultroute6="$GATEWAY6"
RCC
	fi
	if [ -n "${DNS-}" ]; then
		: > $MNT/etc/resolv.conf
		for _ns in $DNS; do
			echo "nameserver $_ns" >> $MNT/etc/resolv.conf
		done
	fi
else
	cat >> $MNT/etc/rc.conf <<RCC
dhcpcd=YES
dhclient=YES
RCC
fi

# swap を fstab に書いたなら no_swap は要らない。書いていない版は swap の
# 無いディスクで回るので、探しに行かせない。
if [ -z "${SWAPDEV-}" ]; then
	echo "no_swap=YES" >> $MNT/etc/rc.conf
fi

# 起動して自分で広がるようにする。
#
# VPS 向けの版はどちらも、焼いたときの大きさの MBR と disklabel を持ったまま、
# それより大きいディスクの先頭に載る。Vultr は 10GB のディスクに 1.75GiB の
# snapshot を書き戻すし、さくらは 200GB のディスクの先頭に dd する。理由は
# 別々で、前者は release の asset 2GiB の上限、後者は戻せない窓を短くしたい
# から。結果は同じで、残りが空いたままになる。
#
# **mount したまま resize_ffs を掛けてはいけない。** 拒否されないのに壊れる。
# カーネルが持っている superblock は古いままなので、伸ばした直後に書くと
# bitmap が食い違い、fsck が UNRESOLVED INCONSISTENCIES REMAIN を出す。実際に
# qemu で踏んだ。
#
# NetBSD にはそのための段が用意されている。rc.d の並びが
#
#	fsck_root -> [ここ] -> root (mount -u -w /) -> mountcritlocal
#
# になっていて、resize_root がその間に走る。root はまだ read-only なので、
# 書いた superblock がカーネルの古い写しに潰されない。
#
# 足りないのは label の方。rc.conf の既定に resize_disklabel という名前はあるが、
# 実装は stock の rc.d ではなく distrib/utils/embedded/files/ に置かれていて、
# arm と liveimage がそこから自分の etc/rc.d へ焼き込んでいる。変数だけ既定に
# あるのは rc を黙らせるためで、意図的なもの (「Used by arm images and is not
# part of the stock rc.d yet」)。だから etc セットには入ってこない。
#
# その上流版はここでは使えない。NetBSD が MBR の #1 にある前提で PART1ID を見る
# が、mkimg.sh は #0 に置く。そして disklabel -i に $ を流して root を末尾まで
# 伸ばすので、末尾に swap を残せない。dd で入れ替える版は書き戻す元をそこに置く
# ので、そこが要る。取り方だけ上流に倣う。
#
# vultr/README.md は長いこと「使うなら MBR と disklabel を広げて resize_ffs を
# 掛ける」と書いていたが、instance にはその root しか無く、それは mount されて
# いる。読んだとおりに実行すると上の壊れ方をする。仕掛けはプロファイルに依らな
# いので、両方に焼いて README のその段落を消す。
if [ $VPS = yes ]; then
	cat > $MNT/etc/rc.d/growlabel <<'GLBL'
#!/bin/sh
#
# PROVIDE: growlabel
# REQUIRE: fsck_root
# BEFORE: resize_root
# KEYWORD: interactive
#
# 焼いたときの大きさの disklabel を、実際のディスク一杯まで広げる。fs の方は
# 続けて走る resize_root が伸ばす。
#
# growlabel_swap に sector 数を渡すと、その分をディスクの末尾に b: として残す。
# dd の元にした控えをそこに置いてあるうちは fstab に swap を書かないこと。
# swapon した時点で控えが消える。
#
# 広げられなくても起動は続ける。小さいまま上がれば ssh で入って手で直せるが、
# ここで止めるとコンソールの無い箱は失われる。
#
# / がまだ read-only なので中間ファイルは置けない。label は変数に読み、書き
# 戻しはパイプと /dev/stdin で渡す。

$_rc_subr_loaded . /etc/rc.subr

name="growlabel"
rcvar=$name
start_cmd="growlabel_start"
stop_cmd=":"

growlabel_start()
{
	local dev disk total swap asize boff cur have

	dev=$(sysctl -n kern.root_device) || return 0
	disk=${dev%[a-p]}
	[ -n "$disk" ] || return 0

	# 実寸はドライバに訊く。on-disk の label は焼いたときの大きさを言うので
	# 当てにならない。取り方は distrib/utils/embedded/files/resize_disklabel
	# に倣った。
	#
	# 落ちたときの控えが fdisk -S で、DLSIZE は label 側なので使えない。
	# 欲しいのは BIOS 側の BDLSIZE。人間向けの出力を削るより確実。
	total=$(drvctl -p "$disk" disk-info/geometry/sectors-per-unit 2>/dev/null)
	case "$total" in
	''|*[!0-9]*)
		eval "$(fdisk -S "$disk" 2>/dev/null)"
		total=${BDLSIZE-} ;;
	esac
	case "$total" in
	''|*[!0-9]*)	echo "growlabel: $disk の大きさが読めない"; return 0 ;;
	esac

	cur=$(disklabel -r "$disk" 2>/dev/null) || return 0
	have=$(printf '%s\n' "$cur" | awk '/^total sectors:/ { print $3 }')
	if [ "$have" = "$total" ]; then
		echo "Not resizing $disk label: already correct size"
		return 0
	fi

	swap=${growlabel_swap:-0}
	case "$swap" in
	''|*[!0-9]*)	swap=0 ;;
	esac

	boff=$((total - swap))
	asize=$((boff - 63))
	[ "$asize" -gt 0 ] || { echo "growlabel: 広げる先が無い"; return 0; }

	echo "Resizing $disk label to $total sectors"
	fdisk -f -u -0 -s "169/63/$((total - 63))" -a "$disk" > /dev/null 2>&1 ||
		{ echo "growlabel: fdisk が失敗した"; return 0; }

	# a: の fsize/bsize/cpg は焼いたときの newfs に合わせてあるので、読んだ
	# ものをそのまま書き戻す。決め打ちにすると fs と label が食い違う。
	# unused の行は fsize と bsize まで書かないと "too few fields" で撥ねられる。
	if printf '%s\n' "$cur" | awk \
		-v tot="$total" -v cyl="$((total / 1008))" \
		-v asz="$asize" -v swp="$swap" -v boff="$boff" '
		/^total sectors:/ { print "total sectors: " tot; next }
		/^cylinders:/	  { print "cylinders: " cyl; next }
		/^ a:/ { printf " a: %9d %9d %10s %6s %5s %4s\n", \
				 asz, 63, $4, $5, $6, $7
			 if (swp > 0)
				printf " b: %9d %9d %10s\n", swp, boff, "swap"
			 next }
		/^ b:/ { next }
		/^ c:/ { printf " c: %9d %9d %10s %6d %5d\n", tot - 63, 63, "unused", 0, 0; next }
		/^ d:/ { printf " d: %9d %9d %10s %6d %5d\n", tot, 0, "unused", 0, 0; next }
		{ print }
	' | disklabel -R -r "$disk" /dev/stdin; then
		echo "growlabel: $disk を $total sector にした"
	else
		echo "growlabel: disklabel が失敗した。小さいまま続ける"
	fi
	return 0
}

load_rc_config $name
run_rc_command "$1"
GLBL
	chmod 555 $MNT/etc/rc.d/growlabel
	# 伸ばしたら、その場で落とす。
	#
	# resize_ffs は root が read-only の間に新しい superblock を書くが、
	# カーネルはまだ焼いたときの大きさの写しを抱えている。そのまま
	# mount -u -w / して multi-user まで行くと、古い写しが書き戻されて
	# 伸びが無かったことになり、しかも bitmap が食い違って fsck が
	# UNRESOLVED INCONSISTENCIES REMAIN を出す。qemu で dumpfs を見て
	# 確かめた: 「Resizing / 」と言った後の on-disk が元の大きさのまま。
	#
	# reboot -n は sync しないので、書いた superblock がそのまま残る。
	# 二度目の起動でカーネルが読み直し、resize_ffs -c が「もう合っている」
	# と言うので postcmd は二度と走らない。ループにはならない。
	cat >> $MNT/etc/rc.conf <<RCC
growlabel=YES
growlabel_swap=${SWAPSECT:-0}
resize_root=YES
resize_root_postcmd="/sbin/reboot -qn"
RCC
fi

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
#
# どこに出すかは相手による。Vultr にシリアルは無く、見えるのは VGA を覗く
# web console だけなので pc のまま置く。さくらの VPS はシリアルで、今の
# techne が com0 で上がっているのがその証拠。CONSDEV で選ぶ。
if [ $USE_MBR = yes ] && [ "$MAJOR" -ge 5 ] 2>/dev/null; then
	if [ "${CONSDEV:-com0}" = pc ]; then
		cat > $MNT/boot.cfg <<BCFG
menu=Boot normally:boot
default=1
timeout=2
BCFG
	else
		cat > $MNT/boot.cfg <<BCFG
menu=Boot normally:consdev $CONSDEV;boot
default=1
timeout=2
consdev=$CONSDEV
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

# dhcpcd の既定は slaac private で、RFC 7217 の乱数識別子から住所を作る。
# Vultr は MAC から EUI-64 で作った住所を台帳に載せ、API の v6_main_ip も
# それを返すので、guest が乱数を選ぶと両者が 食い違う。/64 は丸ごと経路
# 付けされているので通信自体は成立するが、API で住所を引いて ssh する側から
# は「起動しているのに繋がらない機械」にしか見えない。実際にこれで半日
# 溶かした。hwaddr にすると Vultr が言う住所そのものが付く。
if [ $PROFILE = vultr ] && [ -f $MNT/etc/dhcpcd.conf ]; then
	sed -e 's/^slaac private/slaac hwaddr/' $MNT/etc/dhcpcd.conf \
		> $MNT/etc/dhcpcd.conf.new &&
		mv $MNT/etc/dhcpcd.conf.new $MNT/etc/dhcpcd.conf
	# 置換は行が在ることが前提で、綴りが変わると黙って何もしない。効いた
	# かどうかは住所が食い違って初めて分かるので、ここで確かめて足す。
	grep -q '^slaac hwaddr' $MNT/etc/dhcpcd.conf ||
		echo 'slaac hwaddr' >> $MNT/etc/dhcpcd.conf
fi

mkdir -p $MNT/root/.ssh
cat $PUBKEY > $MNT/root/.ssh/authorized_keys
chmod 700 $MNT/root/.ssh
chmod 600 $MNT/root/.ssh/authorized_keys
# 鍵だけで入れるようにする。パスワードは誰にも設定していないので今すぐの
# 実害は無いが、後から誰かがパスワードを付けたときに、そこが入口になる。
#
# KbdInteractiveAuthentication は OpenSSH 8.7 で
# ChallengeResponseAuthentication から改名されたもので、それより古い sshd は
# 知らない語を見ると起動そのものを拒む。ここは 1.x まで焼くので、その語が
# 通る 10 以降にだけ書く。PasswordAuthentication はどの版でも通る。
cat >> $MNT/etc/ssh/sshd_config <<SSHD
PermitRootLogin prohibit-password
PasswordAuthentication no
SSHD
if [ "$MAJOR" -ge 10 ] 2>/dev/null; then
	echo 'KbdInteractiveAuthentication no' >> $MNT/etc/ssh/sshd_config
fi

mkdir -p $MNT/kern $MNT/proc $MNT/dev/pts
( cd $MNT/dev && sh MAKEDEV all ) > /dev/null 2>&1 || echo "    (MAKEDEV 省略)"

# 証明書を張る。
#
# 焼いたイメージは /etc/openssl/certs が空で、**https を一切引けない。** 信頼点
# そのものは base の /usr/share/certs/mozilla に 150 個入っているが、それを
# /etc/openssl/certs へ展開するのは sysinst の仕事で、セットを直接展開して作る
# この方法にはその段が無い。
#
# 気づきにくいのは、pkg_add が返すのが証明書の話ではなく "no pkg found for
# 'pkgin', sorry" だから。置き場が悪いのだと思って URL を疑うことになる。
# 実機に入れ替えてから踏んだ。
#
# certctl は展開先を引数で選べないので chroot して走らせる。ホストと相手の arch
# が違うと動かないので、そのときは黙って飛ばす。起動してから certctl rehash を
# 打てば済む。
if [ -x $MNT/usr/sbin/certctl ] && [ -d $MNT/usr/share/certs ]; then
	if chroot $MNT /usr/sbin/certctl rehash > /dev/null 2>&1; then
		echo "    (証明書 $(ls $MNT/etc/openssl/certs 2>/dev/null | wc -l) 本)"
	else
		echo "    (certctl は走らなかった。起動してから rehash すること)"
	fi
fi

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

# VPS 向けは固めない。Vultr の snapshot-from-URL は raw しか受け取らないし、
# さくらの版は dd の入力にそのまま食わせる。
if [ $VPS = yes ]; then
	ls -l $IMG
	case $PROFILE in
	vultr)	echo "OK: $IMG (raw のまま。公開 URL に置いて vultr/up.yml に渡す)" ;;
	sakura)	echo "OK: $IMG (raw のまま。swap へ dd してから先頭へ書き戻す)" ;;
	esac
else
	echo "--- 圧縮 ---"
	gzip -9 $IMG
	ls -l $IMG.gz
	echo "OK: $IMG.gz"
fi
