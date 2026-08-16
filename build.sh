#!/bin/sh
# NetBSD 以外も含めた一台を起こし、届くところまでを確かめる。
#
#   sh build.sh <target>
#   例: sh build.sh sunos-4.1.4-sparc
#
# 何をどう起こすかは targets/<target>.conf に書く。手で通した手順をそのまま
# 書き写せる形にしてある。実際 SunOS 4.1.4 は、手でコンソールに打った三手
# (root で入る、IP を振り直す、経路を足す) をそのまま STEPS にしただけ。
#
# 入れ方は幾つかに分かれる。conf の DRIVER で選ぶ。
#
#   prebuilt     展開済みイメージを起こすだけ。手元の SunOS や HP-UX、
#                FreeBSD や DragonFly の公式イメージ
#   anita        sysinst を操る。NetBSD 専用 (build-image.sh)
#   autoinstall  応答ファイルを置く。OpenBSD 専用 (build-openbsd-image.sh)
#   expect       インストーラをコンソールで操る (これから)
#   builder-vm   NetBSD ゲストの中で生ディスクを組む (これから)
#
# 公開してよいかは conf の LICENSE が決める。free 以外は release にも
# artifact にも上げない。CI は free のものしか見ない。
#
# 出来上がりは out/ に置く。リポジトリには入らない。

set -eu

TARGET=${1:-}
[ -n "$TARGET" ] || { echo "usage: $0 <target>   (targets/ を見よ)" >&2; exit 1; }

BASE=${BASE:-$(cd "$(dirname "$0")" && pwd)}
CONF=$BASE/targets/$TARGET.conf
[ -s "$CONF" ] || { echo "$0: $CONF が無い" >&2; exit 1; }

MEDIA_DIR=${MEDIA_DIR:-$BASE/disk_images}
OUTDIR=${OUTDIR:-$BASE/out}
WORK=${WORK:-${TMPDIR:-/tmp}/osimg-$TARGET}
# socket の名前には長さの上限がある (macOS で 104 バイト)。作業場所が深いと
# そこで転ぶので、socket だけは短いところに置く。
TTY=${TTY:-/tmp/$TARGET.tty}

LICENSE=free
DRIVER=prebuilt
IMGFMT=qcow2
BOOT_WAIT=120
STEPS=
CHECK=
SSH=no
MEDIA=
MEDIA_FETCH=
ARCHIVE_MEMBER=
NOTE=
QEMUARGS=
EMU=
OS=; VERSION=; PORT=
# shellcheck disable=SC1090
. "$CONF"

echo "=== $OS $VERSION / $PORT ($DRIVER, $EMU)"
if [ -n "$NOTE" ]; then echo "    $NOTE"; fi
if [ "$LICENSE" != free ]; then
	# 変数の直後に日本語を置かない。macOS の bash は多バイト文字を
	# 変数名の一部として読み、unbound variable で止まる。
	echo "    !! license=${LICENSE}。出来たものを release にも artifact にも"
	echo "       上げないこと。手元と self-hosted 専用。"
fi

case $DRIVER in
prebuilt)	;;
anita)		exec sh "$BASE/build-image.sh" "$PORT" "$VERSION" ;;
autoinstall)	exec sh "$BASE/build-openbsd-image.sh" "$PORT" "$VERSION" ;;
*)		echo "$0: driver $DRIVER はまだ書いていない" >&2; exit 1 ;;
esac

command -v "$EMU" > /dev/null 2>&1 || { echo "$0: $EMU が無い" >&2; exit 1; }

mkdir -p "$WORK" "$OUTDIR"
IMG=$OUTDIR/$TARGET.$IMGFMT

# ------------------------------------------------------------------
# 媒体を用意する。手元に在れば取りに行かない。
if [ ! -s "$IMG" ]; then
	SRC=$MEDIA_DIR/$MEDIA
	if [ ! -s "$SRC" ] && [ -n "$MEDIA_FETCH" ]; then
		echo "--- 手元に無いので取ってくる"
		sh "$BASE/fetch-media.sh" "$MEDIA_FETCH" "$(basename "$MEDIA")"
	fi
	[ -s "$SRC" ] || { echo "$0: 媒体が無い: $MEDIA" >&2; exit 1; }

	echo "--- 展開 ($(basename "$MEDIA"))"
	case $MEDIA in
	*.tar.lz|*.tar.gz|*.tar.xz|*.tgz)
		[ -n "$ARCHIVE_MEMBER" ] || {
			echo "$0: 書庫なので ARCHIVE_MEMBER が要る" >&2; exit 1; }
		rm -rf "$WORK/x"; mkdir -p "$WORK/x"
		case $MEDIA in
		*.lz)	lzip -dc "$SRC" | tar xf - -C "$WORK/x" ;;
		*.xz)	xz -dc "$SRC" | tar xf - -C "$WORK/x" ;;
		*)	gzip -dc "$SRC" | tar xf - -C "$WORK/x" ;;
		esac
		cp "$WORK/x/$ARCHIVE_MEMBER" "$IMG"
		;;
	*.lz)	lzip -dc "$SRC" > "$IMG" ;;
	*.xz)	xz -dc "$SRC" > "$IMG" ;;
	*.gz)	gzip -dc "$SRC" > "$IMG" ;;
	*)	cp "$SRC" "$IMG" ;;
	esac
fi
ls -l "$IMG"

# ------------------------------------------------------------------
# 起こす。
#
# ホスト側の口は使う分だけ開ける。CHECK が tcp:23 なら 23 を、ssh なら 22 を
# 転送する。model を指定しない -nic なら、その機械の既定の NIC が付く。
GUESTPORT=22
case $CHECK in
tcp:*)	GUESTPORT=${CHECK#tcp:} ;;
esac
HOSTPORT=${HOSTPORT:-2222}

rm -f "$TTY" "$OUTDIR/$TARGET.console.log"
DISK=$(echo "$QEMUARGS" | sed "s|@IMG@|$IMG|g")

echo "--- 起動 (console: $OUTDIR/$TARGET.console.log)"
# shellcheck disable=SC2086
"$EMU" $DISK \
	-snapshot \
	-display none -vga none \
	-nic "user,hostfwd=tcp:127.0.0.1:$HOSTPORT-:$GUESTPORT" \
	-serial "unix:$TTY,server,nowait" \
	-monitor none \
	> "$WORK/emu.log" 2>&1 &
EMUPID=$!
trap 'kill $EMUPID 2>/dev/null || true' EXIT INT TERM

# ------------------------------------------------------------------
# 上がってからやること。手で通した手順をそのまま流す。
if [ -n "$STEPS" ]; then
	set --
	OIFS=$IFS; IFS='|'
	for s in $STEPS; do set -- "$@" --step "$s"; done
	IFS=$OIFS
	python3 "$BASE/talk.py" --socket "$TTY" \
		--log "$OUTDIR/$TARGET.console.log" \
		--timeout "$BOOT_WAIT" "$@" || {
		echo "!! 手順の途中で待ちきれなかった。コンソールの末尾:" >&2
		tail -20 "$OUTDIR/$TARGET.console.log" >&2
		exit 1
	}
fi

# ------------------------------------------------------------------
# 届いたか。
#
# QEMU の user networking は、ゲスト側が閉じていてもホスト側の口は繋がって
# しまう。開いたかどうかではなく、何か喋るかどうかで見る。
case $CHECK in
tcp:*)
	echo "--- $HOSTPORT に何か返るか"
	if python3 - "$HOSTPORT" <<'PY'
import socket, sys
s = socket.create_connection(('127.0.0.1', int(sys.argv[1])), 10)
s.settimeout(10)
try:
    d = s.recv(64)
except Exception:
    d = b''
print("返答:", d[:32] or "(無し)")
sys.exit(0 if d else 1)
PY
	then
		echo "OK: ゲストのサービスが応答した"
	else
		echo "!! 何も返らない。ネットワークが上がっていない" >&2
		exit 1
	fi
	;;
ssh)
	echo "--- ssh を待つ"
	n=0
	while [ $n -lt 60 ]; do
		if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		       -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR \
		       -p "$HOSTPORT" root@127.0.0.1 true 2>/dev/null; then
			echo "OK: ssh が通った"
			break
		fi
		n=$((n + 1)); sleep 5
	done
	[ $n -lt 60 ] || { echo "!! ssh が上がらない" >&2; exit 1; }
	;;
esac

# ------------------------------------------------------------------
# 次に起こす人のために、使った形をそのまま書き出す。
cat > "$OUTDIR/$TARGET.qemu" <<META
OS=$OS
VERSION=$VERSION
PORT=$PORT
LICENSE=$LICENSE
VMM=qemu
QEMU=$EMU
FORMAT=$IMGFMT
QEMUARGS="$QEMUARGS"
STEPS="$STEPS"
CHECK=$CHECK
SSH=$SSH
NOTE="$NOTE"
META
echo "--- 繋ぎ方"
cat "$OUTDIR/$TARGET.qemu"
echo "OK: $TARGET"
