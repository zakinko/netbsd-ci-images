#!/bin/sh
# anita で NetBSD を QEMU に入れ、qcow2 に固める。
#
#   sh build-image.sh <arch> <release>
#   例: sh build-image.sh i386 10.1
#
# Linux でも macOS でも動く。NetBSD のコマンドは要らない。anita が QEMU の
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
#
# 出来上がりは <arch>-<release>.qcow2 と、繋ぎ方を書いた <arch>-<release>.qemu。

set -eu

ARCH=$1
REL=$2

BASE=${BASE:-$(cd "$(dirname "$0")" && pwd)}
WORK=${WORK:-${TMPDIR:-/tmp}/nbimg-$ARCH-$REL}
SEED_DIR=${SEED_DIR:-$WORK/seed}
SEED_PORT=${SEED_PORT:-8123}
DISK=${DISK:-12G}
MEM=${MEM:-1024}
OUT=$BASE/$ARCH-$REL

# 9.0 より前は本ミラーから外れて archive にある。
MAJOR=${REL%%.*}
if [ "$MAJOR" -ge 9 ] 2>/dev/null; then
	URL=https://cdn.netbsd.org/pub/NetBSD/NetBSD-$REL/$ARCH/
else
	URL=https://archive.netbsd.org/pub/NetBSD-archive/NetBSD-$REL/$ARCH/
fi

# 入れるセット。既定では絞らない。版によって名前も顔ぶれも違い、知らない
# 名前を渡すと anita が止まるので、全部入れてしまうほうが版をまたいで確実。
# 絞りたいときだけ SETS を渡す。
SETS=${SETS:-}

case $ARCH in
i386)		QEMU=qemu-system-i386 ;;
amd64)		QEMU=qemu-system-x86_64 ;;
sparc64)	QEMU=qemu-system-sparc64 ;;
*)		QEMU=qemu-system-$ARCH ;;
esac

# x86 の guest なら KVM が効く。効かないと emulation になり、install だけで
# 1〜2 時間かかる。
ACCEL=tcg
case $ARCH in
i386|amd64) [ -w /dev/kvm ] && ACCEL=kvm ;;
esac

echo "=== NetBSD $REL / $ARCH ==="
echo "    $URL"
echo "    accel=$ACCEL disk=$DISK mem=${MEM}M"
[ "$ACCEL" = tcg ] && echo "    !! 加速なし。相当遅い。"

command -v anita > /dev/null 2>&1 || {
	echo "$0: anita が無い。pip install pexpect <anita の tar.gz>" >&2
	exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK" "$SEED_DIR"
cp "$BASE/guest-bootstrap.sh" "$SEED_DIR/"

# ゲストは 10.0.2.2 越しにここから bootstrap を取る。切り離しておかないと
# 次の段に進む前に道連れになることがある。
if command -v setsid > /dev/null 2>&1; then
	setsid nohup python3 -m http.server "$SEED_PORT" --bind 0.0.0.0 \
		--directory "$SEED_DIR" > "$WORK/seed.log" 2>&1 &
else
	nohup python3 -m http.server "$SEED_PORT" --bind 0.0.0.0 \
		--directory "$SEED_DIR" > "$WORK/seed.log" 2>&1 &
fi
SEED_PID=$!
trap 'kill $SEED_PID 2>/dev/null || true' EXIT INT TERM
sleep 2

# --run の中身はコンソール越しに打ち込まれるので短くしておく。仕込みは
# guest-bootstrap.sh 側。
#
# 先頭の dhcpcd は要る。anita は NIC を明示しないので qemu の既定がぶら下が
# るだけで、入れたばかりのシステムでは dhcpcd が動いていない。そのままだと
# 10.0.2.2 に届かない。
set -- \
	--workdir "$WORK/anita" \
	--disk-size "$DISK" \
	--memory-size "${MEM}M" \
	--persist \
	--vmm-args "-accel $ACCEL" \
	--run "dhcpcd -w; ftp -o /tmp/bs.sh http://10.0.2.2:$SEED_PORT/guest-bootstrap.sh && sh /tmp/bs.sh"
[ -n "$SETS" ] && set -- "$@" --sets "$SETS"

anita "$@" boot "$URL"

echo "=== qcow2 に固める ==="
rm -f "$OUT.qcow2"
qemu-img convert -O qcow2 -c "$WORK/anita/wd0.img" "$OUT.qcow2"
qemu-img info "$OUT.qcow2" | head -5

# 動かす側がイメージを見ただけでは繋ぎ方が分からないので添える。anita が
# 使った構成に合わせること。食い違うと root が見つからず起動しない。
cat > "$OUT.qemu" <<META
ARCH=$ARCH
RELEASE=$REL
QEMU=$QEMU
FORMAT=qcow2
DISKARGS="-drive file=@IMG@,format=qcow2,cache=unsafe"
NICDEV=
ROOTDEV=wd0a
SEED_PORT=$SEED_PORT
META
echo "--- 繋ぎ方 ---"
cat "$OUT.qemu"

rm -rf "$WORK/anita"
echo "OK: $OUT.qcow2"
