#!/bin/sh
# 意地悪な中身を $1 の下に作る。NetBSD / FreeBSD / Linux の sh で同じに走る。
# 中身そのものは乱数なので毎回違う。比べる相手は同じ回に取った manifest。
set -e
d=$1
mkdir -p "$d"
cd "$d"

rep() { awk -v s="$1" -v n="$2" 'BEGIN{for(i=0;i<n;i++)printf "%s", s}'; }

printf 'hello\n' > small
: > empty
# block と fragment の境目。UFS は 512/4096/32768、NTFS は 4096 の cluster と
# MFT に収まる resident (数百 byte) の境目も跨ぐ。
for n in 1 511 512 513 700 1023 1024 4095 4096 4097 32767 32768 32769 65536 1048575 1048577; do
	dd if=/dev/urandom of=sz$n bs=$n count=1 2>/dev/null
done
dd if=/dev/urandom of=big64m bs=65536 count=1024 2>/dev/null
# 5GiB の位置に 64KiB だけ。32bit の offset や間接ブロックの三段目を踏む。
dd if=/dev/urandom of=sparse5g bs=65536 count=1 seek=81920 2>/dev/null

ln small hl1
ln small hl2
ln -s small sym_short
# UFS は 60 byte (UFS2 は 120) 未満の symlink を inode に収める。その外。
ln -s "$(rep a 200)" sym_long
ln -s ../nowhere sym_dangling

: > "$(rep n 255)"
# 「あ」は UTF-8 で 3 byte。85 個で 255 byte、UTF-16 では 85 単位。
: > "$(rep "$(printf '\343\201\202')" 85)"
printf 'ja\n' > "$(printf '\346\227\245\346\234\254\350\252\236').txt"
: > 'with space'
: > 'colon:name'
: > 'back\slash'
: > 'Case'
: > 'case'

mkdir many
i=0
while [ $i -lt 5000 ]; do : > many/f$i; i=$((i + 1)); done

p=deep
i=0
while [ $i -lt 64 ]; do p=$p/d; i=$((i + 1)); done
mkdir -p "$p"
printf 'bottom\n' > "$p/leaf"

mkfifo fifo
printf 'suid\n' > suid; chmod 4755 suid
printf 'priv\n' > priv; chmod 0600 priv
mkdir sticky; chmod 1777 sticky
printf 'old\n' > t2000; touch -t 200001010000.00 t2000
# 2038 年を越える。UFS1 の時刻は 32bit。
printf 'new\n' > t2040; touch -t 204001010000.00 t2040
if [ "$(id -u)" = 0 ]; then
	printf 'o\n' > owned; chown 1234:5678 owned
	printf 'o\n' > bigid; chown 70000:70000 bigid
fi
