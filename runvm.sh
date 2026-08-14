#!/bin/sh
# イメージを QEMU で起動し、ssh で入れるようになるまで待つ。
#
#   sh runvm.sh <arch>-<release> [ssh ポート]
#   例: sh runvm.sh i386-10.1
#       sh runvm.sh i386-10.1 2223
#
# 繋ぎ方は同じ名前の .qemu から読む。イメージと食い違うと root が見つからず
# 起動しないので、ここで決め打ちにはしない。
#
# 鍵はイメージに焼かれていない。起動のたびにゲストの seed_key が
# http://10.0.2.2:<SEED_PORT>/authorized_keys を取りに来るので、ここで
# 使い捨ての鍵対を作って配る。おかげで secret も固定の鍵も要らない。
#
# イメージは -snapshot で開く。書き込みは捨てられ、落としてきた qcow2 は
# そのまま次の実行にも使える。中身を残したいときは KEEP=1 を渡す。
#
# 止めるときは stopvm.sh を使うこと。QEMU モニタの quit は電源を引き抜くの
# と同じで、FFS が壊れて次回 fsck で長時間待たされるか、起動しなくなる。

set -eu

NAME=$1
PORT=${2:-2222}

DIR=${DIR:-.}
META=$DIR/$NAME.qemu
MEM=${MEM:-2048}
SMP=${SMP:-2}
KEY=${KEY:-$DIR/$NAME.id}
SEED=$DIR/$NAME.seed

[ -s "$META" ] || { echo "$0: $META が無い"; exit 1; }
. "$META"
SEED_PORT=${SEED_PORT:-8123}

# イメージ本体。qcow2 をそのまま使う版と、古い .img.gz の版がある。
if [ -s "$DIR/$NAME.qcow2" ]; then
	IMG=$DIR/$NAME.qcow2
elif [ -s "$DIR/$NAME.img" ]; then
	IMG=$DIR/$NAME.img
elif [ -s "$DIR/$NAME.img.gz" ]; then
	echo "--- 展開 ---"
	gzip -dc "$DIR/$NAME.img.gz" > "$DIR/$NAME.img"
	IMG=$DIR/$NAME.img
else
	echo "$0: $NAME のイメージが無い"; exit 1
fi

command -v "$QEMU" > /dev/null 2>&1 || { echo "$0: $QEMU が無い"; exit 1; }

# ------------------------------------------------------------------
# 使い捨ての鍵を作って配る
mkdir -p "$SEED"
if [ ! -s "$KEY" ]; then
	rm -f "$KEY" "$KEY.pub"
	ssh-keygen -q -t ed25519 -f "$KEY" -N '' -C "$NAME"
fi
cp "$KEY.pub" "$SEED/authorized_keys"

if command -v lsof > /dev/null 2>&1 &&
   lsof -nP -iTCP:"$SEED_PORT" -sTCP:LISTEN > /dev/null 2>&1; then
	echo "$0: ポート $SEED_PORT が塞がっている。" >&2
	echo "   ゲストの rc.d に焼き込んだ番号なので変えられない。" >&2
	echo "   別の VM が動いていないか確かめること。" >&2
	exit 1
fi
if command -v setsid > /dev/null 2>&1; then
	setsid nohup python3 -m http.server "$SEED_PORT" --bind 0.0.0.0 \
		--directory "$SEED" > "$DIR/$NAME.seed.log" 2>&1 &
else
	nohup python3 -m http.server "$SEED_PORT" --bind 0.0.0.0 \
		--directory "$SEED" > "$DIR/$NAME.seed.log" 2>&1 &
fi
echo $! > "$DIR/$NAME.seedpid"

# ------------------------------------------------------------------
# x86 の guest なら KVM が使える。使えないと emulation で 10 倍以上遅い。
ACCEL=
case $QEMU in
qemu-system-i386|qemu-system-x86_64)
	[ -w /dev/kvm ] && ACCEL="-enable-kvm" ;;
esac

# 古いイメージには DISKARGS が無いので DISKIF から組み立てて補う。
[ -n "${DISKARGS:-}" ] || \
	DISKARGS="-drive file=@IMG@,if=${DISKIF:-ide},format=raw,cache=unsafe"
DISK=$(echo "$DISKARGS" | sed "s|@IMG@|$IMG|g")

# NIC の付け方。-netdev だけ渡して -device を付けないと netdev がどこにも
# 繋がらず、しかも -netdev を書いた時点で QEMU は既定の NIC を作らなくなる
# ので、guest はネットワーク無しで起動する (dhcpcd がアドレスを取れず、
# 鍵も取りに来られない)。model を指定しない -nic なら、その machine の
# 既定の NIC が付く。anita がインストール時に使ったのと同じものになる。
if [ -n "${NICDEV:-}" ]; then
	NET="-netdev user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:22 -device $NICDEV,netdev=n0"
else
	NET="-nic user,hostfwd=tcp:127.0.0.1:$PORT-:22"
fi

SNAP=-snapshot
[ "${KEEP:-0}" = 1 ] && SNAP=

echo "=== $NAME を起動 (root=${ROOTDEV:-?} ssh=$PORT${ACCEL:+ KVM}${SNAP:+ 使い捨て}) ==="
$QEMU $ACCEL $SNAP -m $MEM -smp $SMP \
	$DISK \
	$NET \
	-display none \
	-serial "file:$DIR/$NAME.console.log" \
	-monitor "unix:$DIR/$NAME.mon,server,nowait" \
	-pidfile "$DIR/$NAME.pid" \
	-daemonize

echo "--- ssh が上がるのを待つ ---"
n=0
while [ $n -lt 120 ]; do
	if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	       -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR \
	       -i "$KEY" -p "$PORT" root@127.0.0.1 true 2>/dev/null; then
		echo "OK: ssh -i $KEY -p $PORT root@127.0.0.1"
		exit 0
	fi
	n=$((n + 1))
	sleep 5
done

echo "!! 10 分待っても ssh が上がらない。コンソールの末尾:"
tail -40 "$DIR/$NAME.console.log" 2>/dev/null || echo "  (コンソールに何も出ていない)"
echo "--- 鍵を取りに来たか (来ていなければネットワークが上がっていない) ---"
tail -5 "$DIR/$NAME.seed.log" 2>/dev/null
exit 1
