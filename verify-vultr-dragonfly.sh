#!/bin/sh
# 焼いた raw が、配られた先で本当に起動して自分で広がるかを見る。
#
#   sh verify-vultr-dragonfly.sh [版] [ディスクの GiB]
#
# Vultr は 1 GiB のイメージを 10 GiB 以上のディスクへ書き戻す。手元でその形を
# 作るには、raw をそのまま大きなファイルの先頭に置けばよい。起動すると
# rc.d/growdisk が slice と label と fs を伸ばし、一度落ちて上がり直す。
#
# 見るのは三つ。growdisk が走ったか、二度目の起動で上がってくるか、そのとき
# / がディスク一杯になっているか。
set -eu

VER=${1:-6.4.2}
GIB=${2:-4}
TARGET=dragonfly-$VER-x86_64
NAME=$TARGET-vultr

BASE=${BASE:-$(cd "$(dirname "$0")" && pwd)}
OUTDIR=${OUTDIR:-$BASE/out}
WORK=${WORK:-${TMPDIR:-/tmp}/vultr-$TARGET}
IMG=$OUTDIR/$NAME.img
# イメージに焼いた公開鍵に対応する秘密鍵。build-vultr-dragonfly.sh が焼くのは
# ./authorized_keys か ~/.ssh/id_rsa.pub なので、既定はその相方にしてある。
# 別の鍵で焼いたときは KEY= で渡す。
KEY=${KEY:-$HOME/.ssh/id_rsa}
BIG=$WORK/verify-$GIB.img
CONLOG=$OUTDIR/$NAME.verify.log

[ -s "$IMG" ] || { echo "$0: $IMG が無い" >&2; exit 1; }
[ -s "$KEY" ] || { echo "$0: 秘密鍵が無い ($KEY)。KEY= で渡すこと" >&2; exit 1; }
mkdir -p "$WORK"

cp "$IMG" "$BIG"
python3 -c "import os,sys; os.truncate(sys.argv[1], int(sys.argv[2]) * 1024**3)" \
	"$BIG" "$GIB"
echo "=== $GIB GiB のディスクの先頭に置いた"

# emulation のままだと十倍以上遅い。あれば KVM を使う。
ACCEL=
[ -w /dev/kvm ] && ACCEL="-enable-kvm"

free_port() {
	python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}
SSHPORT=${SSHPORT:-$(free_port)}

# 焼いたイメージのコンソールは VGA なので、シリアルにはブートローダのぶんしか
# 来ない。上がってこなかったときに何が出ているかは画面を撮るしかないので、
# モニタを繋いでおく。socket の名前には長さの上限がある (macOS で 104 バイト)
# ので短い所に置く。
MON=/tmp/$NAME.mon
rm -f "$CONLOG" "$MON"
qemu-system-x86_64 $ACCEL -m 1024 -smp 2 \
	-drive file="$BIG",format=raw,if=virtio \
	-nic user,hostfwd=tcp:127.0.0.1:"$SSHPORT"-:22 \
	-display none -serial "file:$CONLOG" \
	-monitor "unix:$MON,server,nowait" > "$WORK/emu.log" 2>&1 &
EMUPID=$!
trap 'kill $EMUPID 2>/dev/null || true' EXIT INT TERM
sleep 2

# 上がってこなかったときのために、画面を一枚撮って残す。root が見つからずに
# 止まっているのか single user に落ちているのかは、これでしか分からない。
# 実際、広げ終わった判定を間違えて single user に落ちていたのは、この一枚で
# 分かった。
screendump() {
	python3 "$BASE/screendump.py" "$MON" "$OUTDIR/$NAME.screen.ppm" || return 0
	if command -v pnmtopng > /dev/null 2>&1; then
		pnmtopng "$OUTDIR/$NAME.screen.ppm" > "$OUTDIR/$NAME.screen.png" &&
			rm -f "$OUTDIR/$NAME.screen.ppm"
	fi
	echo "--- 画面を $OUTDIR/$NAME.screen.* に残した"
}

# **loader には何も打たない。** 焼いたイメージのコンソールは VGA のまま
# (Vultr にシリアルが無いため) なので、シリアルで中を見るには loader の促しで
# set console="comconsole" と打つことになるが、この loader は促しを出した直後の
# 何文字かを落とす。boot が bot に、次は oot になって "unknown command" で
# 止まった。打鍵の間隔を 0.08 秒から 0.2 秒に伸ばしても直らない。
#
# 悪いのは、促しに落とすと自動起動の待ち時間も止まることで、一文字落とした
# 時点でその機械は永久に上がってこない。**見るために打った結果、見る対象が
# 起動しない。** だから何も打たず、10 秒待って勝手に起動させる。
#
# 中で何が起きたかは ssh の側で見る。1 GiB で焼いたものが 10 GiB になって
# いれば、growdisk が走った以外に説明が付かない。
echo "=== 起動を待つ (ssh=$SSHPORT)"

SSHCMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o BatchMode=yes -o ConnectTimeout=15 -o LogLevel=ERROR \
	-i $KEY -p $SSHPORT root@127.0.0.1"

# 一度目で広げ、落ちて、二度目で上がってくる。二度ぶんの起動を待つ。
echo "=== 広げて落ちて、上がり直すのを待つ"
n=0
while [ $n -lt 150 ]; do
	if $SSHCMD true 2>/dev/null; then break; fi
	n=$((n + 1)); sleep 5
done
[ $n -lt 150 ] || { screendump; echo "$0: 上がり直してこない" >&2; exit 1; }

echo "=== 上がった"
$SSHCMD 'uname -a; df -h /; fdisk /dev/vbd0 | grep "start 63"' 2>/dev/null |
	sed 's/^/    /'

# / がディスクの大きさに届いているか。1 GiB のまま上がってきたら広げ損ねている。
got=$($SSHCMD "sh -c 'df -k / | tail -1'" 2>/dev/null | awk '{print $2}')
want=$((GIB * 1024 * 1024 * 8 / 10))
[ "$got" -gt "$want" ] ||
	{ screendump; echo "$0: / が $got KB しかない ($GIB GiB のディスクなのに)" >&2; exit 1; }

$SSHCMD 'shutdown -p now' 2>/dev/null || true
n=0
while [ $n -lt 60 ] && kill -0 $EMUPID 2>/dev/null; do n=$((n + 1)); sleep 2; done
kill $EMUPID 2>/dev/null || true
rm -f "$BIG"
echo "OK: $GIB GiB のディスクで起動し、自分で広がった ($got KB)"
