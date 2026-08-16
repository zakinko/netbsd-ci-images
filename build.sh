#!/bin/sh
# 一台を起こし、ssh で入れるところまで確かめる。
#
#   sh build.sh <target>
#   例: sh build.sh freebsd-14.3-amd64
#       sh build.sh sunos-4.1.4-sparc
#
# 何をどう起こすかは targets/<target>.conf に書く。手でコンソールに打って
# 通った手順を、そのまま書き写せる形にしてある。
#
# 入れ方は conf の DRIVER で選ぶ。
#
#   prebuilt     展開済みイメージを起こすだけ。FreeBSD や DragonFly の公式
#                イメージ、手元の SunOS や HP-UX
#   anita        sysinst を操る。NetBSD 専用 (build-image.sh)
#   autoinstall  応答ファイルを置く。OpenBSD 専用 (build-openbsd-image.sh)
#   expect       インストーラをコンソールで操る (これから)
#   builder-vm   NetBSD ゲストの中で生ディスクを組む (これから)
#
# 公開してよいかは LICENSE が決める。free 以外は release にも artifact にも
# 上げない。CI は free のものしか見ない。出来上がりは out/ に置く。

set -eu

TARGET=${1:-}
[ -n "$TARGET" ] || { echo "usage: $0 <target>   (targets/ を見よ)" >&2; exit 1; }

BASE=${BASE:-$(cd "$(dirname "$0")" && pwd)}
CONF=$BASE/targets/$TARGET.conf
[ -s "$CONF" ] || { echo "$0: $CONF が無い" >&2; exit 1; }

MEDIA_DIR=${MEDIA_DIR:-$BASE/disk_images}
OUTDIR=${OUTDIR:-$BASE/out}
WORK=${WORK:-${TMPDIR:-/tmp}/osimg-$TARGET}

LICENSE=free
DRIVER=prebuilt
IMGFMT=qcow2
CONSOLE=socket
BOOT_WAIT=600
STEPS=
SLOW=0
CHECK=
SSH=no
SEED=no
MEDIA=
MEDIA_URL=
MEDIA_FETCH=
ARCHIVE_MEMBER=
NOTE=
QEMUARGS=
EMU=
SSHOPTS=
OS=; VERSION=; PORT=
# shellcheck disable=SC1090
. "$CONF"

echo "=== $OS $VERSION / $PORT ($DRIVER, $EMU)"
if [ -n "$NOTE" ]; then echo "    $NOTE"; fi
if [ "$LICENSE" != free ]; then
	# 変数の直後に日本語を置かない。macOS の bash は多バイト文字を変数名の
	# 一部として読み、unbound variable で止まる。
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

# 空いている番号を借りる。決め打ちにすると、同じ機械で別の VM を動かして
# いるときに取り合いになる。実際、鍵を配る 8123 を別のセッションが握って
# いて、こちらのゲストはそちらの鍵を取ってきてしまい、公開鍵が合わずに
# 入れなかった。原因が分かるまでに何度も起こし直す羽目になっている。
free_port() {
	python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}
SSHPORT=${SSHPORT:-$(free_port)}
SEEDPORT=${SEEDPORT:-$(free_port)}

# ------------------------------------------------------------------
# 媒体を用意する。手元に在れば取りに行かない。
if [ ! -s "$IMG" ]; then
	SRC=$MEDIA_DIR/$MEDIA
	# 配布元が公開しているものは、その URL をここに書いてよい。伏せるのは
	# 再配布の許諾が無いものだけで、そちらは MEDIA_FETCH から取る
	# (取得元はリポジトリに書かない。fetch-media.sh を見よ)。
	if [ ! -s "$SRC" ] && [ -n "$MEDIA_URL" ]; then
		echo "--- 手元に無いので配布元から取る"
		mkdir -p "$(dirname "$SRC")"
		curl -fSL --retry 3 -o "$SRC.part" "$MEDIA_URL" && mv "$SRC.part" "$SRC"
	fi
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
ls -lh "$IMG" | awk '{print "    " $5 "  " $NF}'

# ------------------------------------------------------------------
# 鍵を配る。イメージには焼かない。ゲストは仕込みの途中で一度だけ取りに来る。
# 取りに来る先は STEPS に @SEEDPORT@ で書く。
KEY=$OUTDIR/$TARGET.id
SEEDPID=
if [ "$SEED" = yes ]; then
	mkdir -p "$WORK/seed"
	if [ ! -s "$KEY" ]; then
		rm -f "$KEY" "$KEY.pub"
		ssh-keygen -q -t rsa -b 3072 -f "$KEY" -N '' -C "$TARGET"
	fi
	cp "$KEY.pub" "$WORK/seed/authorized_keys"
	nohup python3 "$BASE/mirror-alias.py" --port "$SEEDPORT" \
		--dir "$WORK/seed" > "$WORK/seed.log" 2>&1 &
	SEEDPID=$!
	sleep 1
fi

# ------------------------------------------------------------------
# 起こす。
#
# コンソールの引き出し方が二通りある。
#
#   socket  -serial unix:… に繋ぐ。firmware がシリアルに出す機械 (sparc、
#           hppa など) はこれでよい
#   stdio   -nographic にして標準入出力越し。x86 の firmware は VGA が在ると
#           そちらにしか出さず、-serial に socket を宛てても一文字も来ない。
#           -vga none にしても変わらず、-nographic のときだけシリアルに出る。
#           ところが -nographic は標準入出力を使うので socket では繋げない。
#           書き出しはファイル、打ち込みは FIFO にする
GUESTPORT=22
case $CHECK in
tcp:*)	GUESTPORT=${CHECK#tcp:} ;;
esac

CONLOG=$OUTDIR/$TARGET.console.log
DISK=$(echo "$QEMUARGS" | sed -e "s|@IMG@|$IMG|g" -e "s|@SEEDPORT@|$SEEDPORT|g")
NET="-nic user,hostfwd=tcp:127.0.0.1:$SSHPORT-:$GUESTPORT"
rm -f "$CONLOG"

echo "--- 起動 (ssh=$SSHPORT seed=$SEEDPORT console=$CONSOLE)"
if [ "$CONSOLE" = stdio ]; then
	FIFO=$WORK/in
	rm -f "$FIFO"; mkfifo "$FIFO"
	# FIFO は読む側と書く側が揃うまで open が返らない。qemu が読む前に
	# 書き手を置いておかないと、両方が相手を待って動かない。
	(sleep 36000 > "$FIFO" &)
	sleep 1
	# shellcheck disable=SC2086
	"$EMU" $DISK -snapshot $NET -nographic < "$FIFO" > "$CONLOG" 2>&1 &
	EMUPID=$!
	TALKIO="--outfile $CONLOG --infile $FIFO"
else
	# socket の名前には長さの上限がある (macOS で 104 バイト)。深いところに
	# 置くとそこで転ぶので、短いところに作る。
	TTY=/tmp/$TARGET.tty
	rm -f "$TTY"
	# shellcheck disable=SC2086
	"$EMU" $DISK -snapshot $NET \
		-display none -vga none \
		-serial "unix:$TTY,server,nowait" -monitor none \
		> "$WORK/emu.log" 2>&1 &
	EMUPID=$!
	TALKIO="--socket $TTY"
fi
trap 'kill $EMUPID 2>/dev/null || true; [ -n "$SEEDPID" ] && kill $SEEDPID 2>/dev/null || true' EXIT INT TERM

# ------------------------------------------------------------------
# 上がってからやること。手で通した手順をそのまま流す。
if [ -n "$STEPS" ]; then
	set --
	OIFS=$IFS; IFS='|'
	for s in $STEPS; do
		set -- "$@" --step "$(echo "$s" | sed "s|@SEEDPORT@|$SEEDPORT|g")"
	done
	IFS=$OIFS
	# shellcheck disable=SC2086
	python3 "$BASE/talk.py" $TALKIO --log "$CONLOG" \
		--timeout "$BOOT_WAIT" --slow "$SLOW" "$@" || {
		echo "!! 手順の途中で待ちきれなかった。コンソールの末尾:" >&2
		tail -c 800 "$CONLOG" | tr -d '\r' >&2
		exit 1
	}
fi

# ------------------------------------------------------------------
# 届いたか。
SSHCMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15 -o LogLevel=ERROR $SSHOPTS -i $KEY -p $SSHPORT root@127.0.0.1"
case $CHECK in
tcp:*)
	# qemu の user networking は、ゲスト側が閉じていてもホスト側の接続は
	# 成立してしまう。開いたかではなく、何か喋るかで見る。
	echo "--- $SSHPORT に何か返るか"
	python3 - "$SSHPORT" <<'PY' || { echo "!! 何も返らない" >&2; exit 1; }
import socket, sys
s = socket.create_connection(('127.0.0.1', int(sys.argv[1])), 15)
s.settimeout(15)
try:
    d = s.recv(64)
except Exception:
    d = b''
print("    返答:", d[:32] or "(無し)")
sys.exit(0 if d else 1)
PY
	echo "OK: ゲストのサービスが応答した"
	;;
ssh)
	echo "--- ssh を待つ"
	n=0
	while [ $n -lt 60 ]; do
		if $SSHCMD true 2>/dev/null; then break; fi
		n=$((n + 1)); sleep 5
	done
	[ $n -lt 60 ] || { echo "!! ssh が上がらない" >&2; exit 1; }
	echo "OK: ssh が通った"
	$SSHCMD 'uname -a' 2>/dev/null | sed 's/^/    /'
	printf '%s\n' "$SSHCMD" > "$OUTDIR/$TARGET.ssh"
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
CONSOLE=$CONSOLE
QEMUARGS="$QEMUARGS"
STEPS="$STEPS"
CHECK=$CHECK
SSH=$SSH
NOTE="$NOTE"
META
echo "OK: $TARGET  ($OUTDIR/$TARGET.qemu)"
