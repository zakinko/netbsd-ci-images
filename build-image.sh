#!/bin/sh
# anita で NetBSD を入れ、動かせる形に固める。
#
#   sh build-image.sh <port> <release>
#   例: sh build-image.sh i386 10.1
#       sh build-image.sh macppc 9.4
#       sh build-image.sh riscv64 netbsd-11      (daily からしか組めない port)
#
# port は ports.conf にある名前。組める組み合わせは gen-targets.sh が出す。
#
# Linux でも macOS でも動く。NetBSD のコマンドは要らない。anita が emulator の
# 中で sysinst を操って入れるので、出来たイメージがその仮想ハードウェアで
# 動くことは作った時点で分かる。外から組み立てる方法だと、guest が虚仮に
# された周辺機器を扱えるかは運任せになる (NetBSD 5 を IDE で組んだら
# "piixide0: lost interrupt" を繰り返して起動しなかった)。
#
# anita の入れ方に注意。PyPI の "anita" は同名の別物なので、本家の配布物を
# 直接指すこと。
#
#	pip install pexpect \
#	    https://www.gson.org/netbsd/anita/download/anita-2.18.tar.gz
#
# ISO を焼く道具も要る。Linux なら genisoimage、macOS なら mkisofs。
# QEMU 以外の port には gxemul か simh も要る。
#
# 出来上がりは
#
#	<port>-<release>.qcow2   イメージ (gxemul/simh の port は .img.gz)
#	<port>-<release>.qemu    動かし方
#	<port>-<release>.kernel  外から渡す必要のあるカーネル (要る port だけ)
#	<port>-<release>.bootiso 起動用の CD (macppc だけ)

set -eu

PORT=$1
REL=$2

BASE=${BASE:-$(cd "$(dirname "$0")" && pwd)}
. "$BASE/common.sh"

ARCH=$(port_field "$PORT" 2)
VMM=$(port_field "$PORT" 3)
EMU=$(port_field "$PORT" 4)
[ -n "$ARCH" ] || { echo "$0: $PORT は ports.conf に無い" >&2; exit 1; }

NAME=$PORT-$REL
WORK=${WORK:-${TMPDIR:-/tmp}/nbimg-$NAME}
SEED_DIR=${SEED_DIR:-$WORK/seed}
SEED_PORT=${SEED_PORT:-8123}
# 出来上がりの置き場。既定は道具と同じところ。
OUTDIR=${OUTDIR:-$BASE}
OUT=$OUTDIR/$NAME

# 版を数で比べる。ブランチ名 (netbsd-11, HEAD) は一番新しいものとして扱う。
case $REL in
HEAD|netbsd-*)	RELN=99000000; MAJOR=99 ;;
*)		RELN=$(relnum "$REL"); MAJOR=${REL%%.*} ;;
esac

# ------------------------------------------------------------------
# ディスクをどう繋ぐか。ここで先に決めるのは、ゲストの中で走らせる仕込みに
# 渡す必要があるため -- 繋ぎ方が変われば /etc/fstab の書き方も変わり、
# 食い違うと root が見つからず起動しない。
#
# IDE はコマンドを一つずつしか処理できずキューが無い。pkgsrc のビルドは
# 小さい書き込みが大量に出るので、一件ごとに往復を待つぶんが積み上がる。
# virtio-blk なら並べて投げられるうえ、実在のチップのレジスタ操作を qemu が
# 模倣する手間も消える。
#
# virtio-blk は NetBSD 6.0 から (それ以前には無い)。10 以降なら vioscsi も
# 使えるが、blk で足りるので版で分けない。
#
#	virtio -> ld0	ide -> wd0
#
WANT_DISKIF=ide
WANT_ROOTDEV=wd0a
case $PORT in
i386|amd64)
	if [ "$MAJOR" -ge 6 ] 2>/dev/null; then
		WANT_DISKIF=virtio
		WANT_ROOTDEV=ld0a
	fi ;;
esac

# ディスクとメモリ。古い版に今の大きさを渡すと、sysinst が扱えなかったり
# 起動の途中で止まったりする。1.x は BIOS のジオメトリの都合もあるので
# 小さめにしておく。
if [ -z "${DISK:-}" ]; then
	if [ "$RELN" -lt 2000000 ]; then DISK=2G
	elif [ "$RELN" -lt 4000000 ]; then DISK=4G
	else DISK=12G
	fi
fi
if [ -z "${MEM:-}" ]; then
	MEM=$(port_field "$PORT" 5)
	if [ "$RELN" -lt 4000000 ] && [ "$MEM" -gt 256 ]; then MEM=256; fi
fi

DISTURL=$(dist_url "$PORT" "$REL") || {
	echo "$0: $NAME の配布ツリーが見つからない" >&2
	exit 1
}

echo "=== NetBSD $REL / $PORT (anita では $ARCH) ==="
echo "    $DISTURL"
echo "    vmm=$VMM emu=$EMU disk=$DISK mem=${MEM}M"

command -v anita > /dev/null 2>&1 || {
	echo "$0: anita が無い。pip install pexpect <anita の tar.gz>" >&2
	exit 1
}
command -v "$EMU" > /dev/null 2>&1 || {
	echo "$0: $EMU が無い" >&2
	exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK" "$SEED_DIR"
cp "$BASE/guest-bootstrap.sh" "$SEED_DIR/"

# ------------------------------------------------------------------
# ゲスト側の ssh をどうするか。
#
# base の sshd は版によって喋れるものが違う。
#
#   2.0 以降   OpenSSH 3.6 以降。今の ssh からでも、古い kex と cipher を
#              明示的に許せば入れる
#   1.6.x      OpenSSH 3.4。SSH2 の ssh-rsa は通る。同上
#   1.5.x      OpenSSH 2.x。SSH2 は DSA しか無い。今の ssh は 10.0 で DSA を
#              落としたので、ホスト側が新しいと入れなくなる
#   1.4 以前   ssh そのものが base に無い
#
# 1.5.x 以前は、イメージを作るときに OpenSSH を組んで sshd を差し替える。
# 版に釣り合う古い pkgsrc とその distfile は今では揃わないので、pkgsrc の
# 木は使わず、pkgsrc がやるのと同じことを配布物から直接やる。tarball は
# ホストが取ってきてこのポートから配る。ゲストから https は引けないし
# (当時の ftp に TLS は無い)、外に出られない環境でも組めるようにするため。
SSH_MODE=base
SSHOPTS=
if [ "$RELN" -lt 6000000 ]; then
	# 今の OpenSSH が既定で断るものを名指しで許す。新しい sshd には無害。
	SSHOPTS="-o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 -o HostkeyAlgorithms=+ssh-rsa,ssh-dss -o PubkeyAcceptedAlgorithms=+ssh-rsa,ssh-dss -o Ciphers=+aes128-cbc,3des-cbc -o MACs=+hmac-sha1,hmac-md5"
fi
if [ "$RELN" -lt 1006000 ]; then
	SSH_MODE=build
fi

if [ "$SSH_MODE" = build ]; then
	# 版に依らず組める古さのものを選ぶ。OpenSSH 3.9p1 は gcc 2.95 と
	# OpenSSL 0.9.x で通り、SSH2 の ssh-rsa を喋る。OpenSSL は 1.5 の
	# base には入っているが 1.4 以前には無いので、無ければ先に組む。
	echo "--- 古い版なので OpenSSH を組んで差し替える。tarball を取る ---"
	fetch_to() {
		[ -s "$2" ] && return 0
		for u in $1; do
			curl -fsSL -m 300 -o "$2" "$u" && return 0
		done
		echo "$0: $2 が取れなかった" >&2
		return 1
	}
	fetch_to "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-3.9p1.tar.gz
		 https://ftp.jaist.ac.jp/pub/OpenBSD/OpenSSH/portable/openssh-3.9p1.tar.gz" \
		"$SEED_DIR/openssh.tar.gz" || true
	fetch_to "https://www.openssl.org/source/old/0.9.x/openssl-0.9.6m.tar.gz
		 https://artfiles.org/openssl.org/source/old/0.9.x/openssl-0.9.6m.tar.gz" \
		"$SEED_DIR/openssl.tar.gz" || true
fi

# ------------------------------------------------------------------
# 手元に中継を立てる。役目は二つ。
#
#   ゲストが起動のたびに取りに来る authorized_keys を配る
#   anita に見せる配布ツリーの名前を揃える (詳しくは mirror-alias.py)
#
# 切り離しておかないと次の段に進む前に道連れになることがある。
NOHUP=nohup
if command -v setsid > /dev/null 2>&1; then NOHUP="setsid nohup"; fi
# shellcheck disable=SC2086
$NOHUP python3 "$BASE/mirror-alias.py" --port "$SEED_PORT" \
	--dir "$SEED_DIR" --alias "$ARCH=$DISTURL" \
	> "$WORK/seed.log" 2>&1 &
SEED_PID=$!
trap 'kill $SEED_PID 2>/dev/null || true' EXIT INT TERM
sleep 2
url_exists "http://127.0.0.1:$SEED_PORT/guest-bootstrap.sh" || {
	echo "$0: 中継が上がらない。$WORK/seed.log:" >&2
	cat "$WORK/seed.log" >&2
	exit 1
}
ANITA_URL="http://127.0.0.1:$SEED_PORT/$ARCH/"

# ------------------------------------------------------------------
# 入れるセット。指定しないと anita の既定になり、X が落ちる。X が無いと
# pkgsrc の X11 を使うものが "uses X11, but /usr/X11R7 not found" で建たない。
# Xvfb は xserver に入っているので、画面のいらない検査にもこれが要る。
#
# 何が在るかは版で違うので、その版の binary/sets/ を見て決める (common.sh)。
# 展開済みイメージから起こす port では sysinst を通らないので指定しない。
SETS=
if [ "$(port_field "$PORT" 7)" = release ]; then
	SETS=${SETS_OVERRIDE:-$(dist_sets "$DISTURL" || true)}
	echo "    sets=$SETS"
fi

# x86 の guest なら KVM が効く。効かないと emulation になり、install だけで
# 1〜2 時間かかる。他の port は常に emulation。
ACCEL=tcg
case $PORT in
i386|amd64) if [ -w /dev/kvm ]; then ACCEL=kvm; fi ;;
esac
if [ "$ACCEL" = tcg ] && [ "$VMM" = qemu ]; then echo "    !! 加速なし。相当遅い。"; fi

set -- \
	--workdir "$WORK/anita" \
	--vmm "$VMM" \
	--disk-size "$DISK" \
	--memory-size "${MEM}M" \
	--persist
if [ -n "$SETS" ]; then set -- "$@" --sets "$SETS"; fi

if [ "$VMM" = qemu ]; then
	set -- "$@" --vmm-args "-accel $ACCEL"
fi

# evbarm の vexpress-a15 は device tree を外から渡さないと起動しない。
# QEMU 自身が持っているものを吐かせて使う。
if [ "$PORT" = evbarm ]; then
	"$EMU" -M vexpress-a15 -m "$MEM" -display none \
		-machine dumpdtb="$WORK/vexpress-a15.dtb" 2>/dev/null || true
	if [ -s "$WORK/vexpress-a15.dtb" ]; then
		set -- "$@" --dtb "$WORK/vexpress-a15.dtb"
	else
		echo "$0: dtb を吐かせられなかった" >&2
		exit 1
	fi
fi

# 入れ終わったゲストの中で一度だけ走らせる仕込み。
#
# コンソール越しに打ち込まれるので短くしておく。中身は guest-bootstrap.sh。
# 先頭の dhcpcd は要る。anita は NIC を明示しないので qemu の既定がぶら下が
# るだけで、入れたばかりのシステムでは dhcpcd が動いていない。そのままだと
# 10.0.2.2 に届かない。dhcpcd は 4.0 から、それ以前は dhclient。
#
# gxemul と simh には外向きの NAT も port forward も無い。ホストから叩く
# 口が無いので、鍵を配る仕掛けは意味を持たない。せめて起動して使える形に
# なるところまでを一行で済ませる。
if [ "$VMM" = qemu ]; then
	RUN="(dhcpcd -w || dhclient -w || dhclient) >/dev/null 2>&1; ftp -o /tmp/bs.sh http://10.0.2.2:$SEED_PORT/guest-bootstrap.sh && SSH_MODE=$SSH_MODE REL=$REL ROOTDEV=$WANT_ROOTDEV sh /tmp/bs.sh"
else
	RUN="echo hostname=nbimg >> /etc/rc.conf; echo sshd=YES >> /etc/rc.conf; echo no_swap=YES >> /etc/rc.conf; sync"
fi
set -- "$@" --run "$RUN"

echo "--- anita $* boot $ANITA_URL ---"
anita "$@" boot "$ANITA_URL"

# ------------------------------------------------------------------
# 出来たものを取り出す。
rm -f "$OUT.qcow2" "$OUT.img" "$OUT.img.gz" "$OUT.kernel" "$OUT.bootiso" "$OUT.dtb"
DL=$WORK/anita/download/$ARCH

# 起動のたびに要るものは、イメージと一緒に置いておく。
if [ -s "$WORK/vexpress-a15.dtb" ]; then cp "$WORK/vexpress-a15.dtb" "$OUT.dtb"; fi

# 外から渡さないと起動しないものを添える。QEMU の alpha には SRM が無く、
# macppc は FFS から起動できず、展開済みイメージの port はブートローダを
# 通らない。いずれもカーネル (や CD) をホスト側から渡すことになる。
copy_kernel_gz() {
	[ -s "$1" ] || return 1
	gzip -dc "$1" > "$OUT.kernel"
}
case $PORT in
alpha|pmax|hpcmips|landisk)
	copy_kernel_gz "$DL/binary/kernel/netbsd-GENERIC.gz" ||
		echo "!! netbsd-GENERIC.gz が無い" >&2
	;;
evbarm|evbarm64|riscv64)
	# anita が展開したものをそのまま使う。名前は版で変わる。
	for k in "$WORK/anita"/netbsd-*.ub "$WORK/anita"/netbsd-GENERIC64.img \
		 "$WORK/anita"/netbsd-GENERIC64 "$WORK/anita"/netbsd-*; do
		[ -f "$k" ] || continue
		case $k in *.gz) continue ;; esac
		cp "$k" "$OUT.kernel"
		break
	done
	[ -s "$OUT.kernel" ] || echo "!! カーネルが見つからない" >&2
	;;
macppc)
	# anita が起動用に焼いた CD (netbsd-GENERIC が入っている)。
	# 名前は anita.py の runtime_boot_iso_path が決めている。
	if [ -s "$WORK/anita/boot.iso" ]; then
		cp "$WORK/anita/boot.iso" "$OUT.bootiso"
	else
		echo "!! 起動用 CD (boot.iso) が見つからない" >&2
	fi
	;;
esac

echo "=== 固める ==="
if [ "$VMM" = qemu ]; then
	qemu-img convert -O qcow2 -c "$WORK/anita/wd0.img" "$OUT.qcow2"
	qemu-img info "$OUT.qcow2" | head -5
	IMGFMT=qcow2
else
	# gxemul も simh も qcow2 は読めない。生のまま圧縮して置く。
	gzip -9c "$WORK/anita/wd0.img" > "$OUT.img.gz"
	ls -l "$OUT.img.gz"
	IMGFMT=raw
fi

# ------------------------------------------------------------------
# 動かす側がイメージを見ただけでは繋ぎ方が分からないので添える。anita が
# 使った構成に合わせること。食い違うと root が見つからず起動しない。
#
# @IMG@ @KERNEL@ @BOOTISO@ @MEM@ は runvm.sh が置き換える。
if [ "$WANT_DISKIF" = ide ]; then
	DISKARGS="-drive file=@IMG@,format=$IMGFMT,media=disk"
else
	DISKARGS="-drive file=@IMG@,format=$IMGFMT,media=disk,if=$WANT_DISKIF"
fi
EXTRAARGS=
ANSWERS=
ROOTDEV=$WANT_ROOTDEV
SSH=yes

case $PORT in
sparc|hppa)
	# どちらも既定の機械のディスクは SCSI。
	ROOTDEV=sd0a
	;;
alpha)
	# QEMU の alpha には SRM が無いので、毎回カーネルを外から渡す。
	EXTRAARGS="-kernel @KERNEL@ -append root=/dev/wd0a"
	;;
macppc)
	# FFS から起動できないので、毎回 CD からカーネルを起こして
	# root だけディスクを使う。root device は聞かれるので答える。
	EXTRAARGS="-M mac99 -prom-env qemu_boot_hack=y -prom-env boot-device=cd:,netbsd-GENERIC -drive file=@BOOTISO@,format=raw,media=cdrom,readonly=on,index=2"
	# 聞かれ方は "root device (default cd0a): " のように既定値が挟まる。
	# anita が install のときに使っているのと同じ形にしておく。
	ANSWERS="root device.*:=>wd0a|dump device.*:=>|file system.*:=>|init path.*:=>"
	;;
evbarm)
	DISKARGS="-drive file=@IMG@,format=$IMGFMT,media=disk,if=sd"
	EXTRAARGS="-M vexpress-a15 -kernel @KERNEL@ -append root=ld0a -dtb @DTB@"
	ROOTDEV=ld0a
	;;
evbarm64)
	# root の指し方が、配布イメージの切り方で変わる。GPT なら
	# ラベルで、MBR なら ld4a。anita も同じ見分け方をしている
	# (512 バイト目から "EFI PART" が始まっていれば GPT)。
	if dd if="$WORK/anita/wd0.img" bs=1 skip=512 count=8 2>/dev/null |
	   grep -q "EFI PART"; then
		ROOTDEV=NAME=netbsd-root
	else
		ROOTDEV=ld4a
	fi
	DISKARGS="-drive file=@IMG@,format=$IMGFMT,media=disk,if=none,id=hd0 -device virtio-blk-device,drive=hd0"
	EXTRAARGS="-M virt -cpu cortex-a57 -kernel @KERNEL@ -append root=$ROOTDEV"
	;;
riscv64)
	DISKARGS="-drive file=@IMG@,format=$IMGFMT,media=disk,if=none,id=hd0 -device virtio-blk-device,drive=hd0"
	EXTRAARGS="-M virt -kernel @KERNEL@ -append root=dk1"
	ROOTDEV=dk1
	;;
pmax)
	DISKARGS="-d @IMG@"
	EXTRAARGS="-e3max -M @MEM@ @KERNEL@"
	ROOTDEV=sd0a
	SSH=no
	;;
hpcmips)
	DISKARGS="-d @IMG@"
	EXTRAARGS="-emobilepro880 -M @MEM@ @KERNEL@"
	SSH=no
	;;
landisk)
	DISKARGS="-d @IMG@"
	EXTRAARGS="-Elandisk -M @MEM@ @KERNEL@"
	SSH=no
	;;
vax)
	DISKARGS=
	EXTRAARGS=
	ROOTDEV=ra0a
	SSH=no
	;;
esac

cat > "$OUT.qemu" <<META
PORT=$PORT
ARCH=$ARCH
RELEASE=$REL
VMM=$VMM
QEMU=$EMU
FORMAT=$IMGFMT
MEM=$MEM
DISKARGS="$DISKARGS"
EXTRAARGS="$EXTRAARGS"
NICDEV=
ROOTDEV=$ROOTDEV
SSH=$SSH
SSHOPTS="$SSHOPTS"
ANSWERS="$ANSWERS"
SEED_PORT=$SEED_PORT
META
echo "--- 繋ぎ方 ---"
cat "$OUT.qemu"

rm -rf "$WORK/anita"
echo "OK: $NAME"
