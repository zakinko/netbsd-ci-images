#!/bin/sh
# イメージを QEMU で起動し、ssh で入れるようになるまで待つ。
#
#   sh runvm.sh <arch>-<release> [ssh ポート]
#   例: sh runvm.sh i386-10.1
#       sh runvm.sh sparc64-11.0 2223
#
# 繋ぎ方は同じ名前の .qemu から読む。イメージと食い違うと root が見つからず
# 起動しないので、ここで決め打ちにはしない。
#
# 止めるときは stopvm.sh を使うこと。QEMU モニタの quit は電源を引き抜くのと
# 同じで、FFS が壊れて次回 fsck で長時間待たされるか、修復に失敗して起動しなく
# なる。

set -e

NAME=$1
PORT=${2:-2222}
[ -n "$NAME" ] || { echo "usage: $0 <arch>-<release> [port]"; exit 1; }

DIR=${DIR:-.}
IMG=$DIR/$NAME.img
META=$DIR/$NAME.qemu
MEM=${MEM:-2048}
SMP=${SMP:-2}

[ -s "$META" ] || { echo "$0: $META が無い"; exit 1; }
. "$META"

if [ ! -s "$IMG" ]; then
	if [ -s "$IMG.gz" ]; then
		echo "--- 展開 ---"
		gzip -dk "$IMG.gz" 2>/dev/null || { gzip -d < "$IMG.gz" > "$IMG"; }
	else
		echo "$0: $IMG も $IMG.gz も無い"; exit 1
	fi
fi

which "$QEMU" > /dev/null 2>&1 || { echo "$0: $QEMU が無い"; exit 1; }

NET="-netdev user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:22"
if [ -n "$NICDEV" ]; then
	NET="$NET -device $NICDEV,netdev=n0"
fi

echo "=== $NAME を起動 (disk=$DISKIF root=$ROOTDEV ssh=$PORT) ==="
# 古いイメージには DISKARGS が無いので、DISKIF から組み立てて補う。
[ -n "$DISKARGS" ] || DISKARGS="-drive file=@IMG@,if=$DISKIF,format=raw,cache=unsafe"
DISK=$(echo "$DISKARGS" | sed "s|@IMG@|$IMG|g")

$QEMU -m $MEM -smp $SMP \
	$DISK \
	$NET \
	-display none \
	-serial file:$DIR/$NAME.console.log \
	-monitor unix:$DIR/$NAME.mon,server,nowait \
	-pidfile $DIR/$NAME.pid \
	-daemonize

echo "--- ssh が上がるのを待つ ---"
# 古い版ほど起動が遅い。TCG での emulation だとさらに掛かる。
n=0
while [ $n -lt 120 ]; do
	if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	       -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR \
	       -p $PORT root@127.0.0.1 true 2>/dev/null; then
		echo "OK: ssh -p $PORT root@127.0.0.1"
		exit 0
	fi
	n=$((n + 1))
	sleep 5
done

echo "!! 2 分待っても ssh が上がらない。コンソールの末尾:"
tail -20 $DIR/$NAME.console.log 2>/dev/null
exit 1
