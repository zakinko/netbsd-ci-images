#!/bin/sh
# VM を正規手順で止める。
#
#   sh stopvm.sh <arch>-<release>
#
# QEMU モニタの quit は電源を引き抜くのと同じで、FFS が壊れる。次回起動時に
# fsck で長時間待たされるか、修復に失敗して起動しなくなる。実際に一度壊して
# 作り直す羽目になっている。
#
# NetBSD は ACPI を拾って正規終了するので、system_powerdown (電源ボタン相当)
# を送る。落ちきったのを確かめてからプロセスを片付ける。

set -e

NAME=$1
[ -n "$NAME" ] || { echo "usage: $0 <arch>-<release>"; exit 1; }

DIR=${DIR:-.}
MON=$DIR/$NAME.mon
PIDF=$DIR/$NAME.pid

[ -s "$PIDF" ] || { echo "$0: $PIDF が無い。動いていない?"; exit 0; }
PID=$(cat $PIDF)

if ! kill -0 $PID 2>/dev/null; then
	echo "既に落ちている"
	rm -f $PIDF
	exit 0
fi

echo "--- ACPI の電源ボタンを押す ---"
if [ -S "$MON" ]; then
	echo system_powerdown | nc -U "$MON" > /dev/null 2>&1 || true
else
	echo "!! モニタ socket が無いので kill -TERM で代用する" >&2
	kill -TERM $PID 2>/dev/null || true
fi

echo "--- 落ちるのを待つ ---"
n=0
while [ $n -lt 60 ]; do
	if ! kill -0 $PID 2>/dev/null; then
		echo "OK: 正規終了した"
		rm -f $PIDF
		# 鍵を配っていた HTTP も片付ける。残すと次の起動でポートを
		# 取り合い、後から来たほうが黙って繋がらないまま進む。
		if [ -s "$DIR/$NAME.seedpid" ]; then
			kill "$(cat $DIR/$NAME.seedpid)" 2>/dev/null || true
			rm -f "$DIR/$NAME.seedpid"
		fi
		exit 0
	fi
	n=$((n + 1))
	sleep 2
done

echo "!! 2 分待っても落ちない。コンソールの末尾:"
tail -20 $DIR/$NAME.console.log 2>/dev/null
echo "!! 手で確かめること。ここで kill -9 すると FFS が壊れる。" >&2
exit 1
