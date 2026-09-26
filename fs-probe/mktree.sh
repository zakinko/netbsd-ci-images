#!/bin/sh
# 意地悪な中身を $1 の下に作る。NetBSD / FreeBSD / Linux の sh で同じに走る。
# 中身そのものは乱数なので毎回違う。比べる相手は同じ回に取った manifest。
#
# 一つ作れなくても先へ進む。set -e で止めていた頃は、ntfs3 が 5GiB の
# sparse で ENOSPC を返したところで黙って止まり、後ろの 5000 ファイルも
# symlink も作られないまま「書けた」ことになっていた (run 36254316116)。
# 作れなかったものは stderr に出る。exit は失敗の数。
d=$1
mkdir -p "$d" && cd "$d" || exit 99
fails=0
trap 'exit $fails' EXIT
ddq() {
	dd "$@" 2> .dd.err || { echo "FAIL: dd $*: $(tail -1 .dd.err)" >&2; fails=$((fails + 1)); }
	rm -f .dd.err
}
chk() { [ $? = 0 ] || { echo "FAIL: $1" >&2; fails=$((fails + 1)); }; }

rep() { awk -v s="$1" -v n="$2" 'BEGIN{for(i=0;i<n;i++)printf "%s", s}'; }

printf 'hello\n' > small
chk "printf hello\n > small"
: > empty
chk ": > empty"
# block と fragment の境目。UFS は 512/4096/32768、NTFS は 4096 の cluster と
# MFT に収まる resident (数百 byte) の境目も跨ぐ。
for n in 1 511 512 513 700 1023 1024 4095 4096 4097 32767 32768 32769 65536 1048575 1048577; do
	ddq if=/dev/urandom of=sz$n bs=$n count=1
done
ddq if=/dev/urandom of=big64m bs=65536 count=1024
# 5GiB の位置に 64KiB だけ。32bit の offset や間接ブロックの三段目を踏む。
ddq if=/dev/urandom of=sparse5g bs=65536 count=1 seek=81920

ln small hl1
chk "ln small hl1"
ln small hl2
chk "ln small hl2"
ln -s small sym_short
chk "ln -s small sym_short"
# UFS は 60 byte (UFS2 は 120) 未満の symlink を inode に収める。その外。
ln -s "$(rep a 200)" sym_long
chk "ln -s \$(rep a 200) sym_long"
ln -s ../nowhere sym_dangling
chk "ln -s ../nowhere sym_dangling"

: > "$(rep n 255)"
chk ": > \$(rep n 255)"
# 「あ」は UTF-8 で 3 byte。85 個で 255 byte、UTF-16 では 85 単位。
: > "$(rep "$(printf '\343\201\202')" 85)"
chk ": > \$(rep \$(printf \343\201\202) 85)"
printf 'ja\n' > "$(printf '\346\227\245\346\234\254\350\252\236').txt"
chk "printf ja\n > \$(printf \346\227\245\346\234\254\35"
: > 'with space'
chk ": > with space"
: > 'colon:name'
chk ": > colon:name"
: > 'back\slash'
chk ": > back\slash"
: > 'Case'
chk ": > Case"
: > 'case'
chk ": > case"

mkdir many
chk "mkdir many"
i=0
while [ $i -lt 5000 ]; do
	: > many/f$i 2>/dev/null || mf=$((${mf:-0} + 1))
	i=$((i + 1))
done
[ ${mf:-0} = 0 ] || { echo "FAIL: many/: ${mf} of 5000 not created" >&2; fails=$((fails + 1)); }

p=deep
i=0
while [ $i -lt 64 ]; do p=$p/d; i=$((i + 1)); done
mkdir -p "$p"
chk "mkdir -p \$p"
printf 'bottom\n' > "$p/leaf"
chk "printf bottom\n > \$p/leaf"

mkfifo fifo
chk "mkfifo fifo"
printf 'suid\n' > suid; chmod 4755 suid
chk "printf suid\n > suid; chmod 4755 suid"
printf 'priv\n' > priv; chmod 0600 priv
chk "printf priv\n > priv; chmod 0600 priv"
mkdir sticky; chmod 1777 sticky
chk "mkdir sticky; chmod 1777 sticky"
printf 'old\n' > t2000; touch -t 200001010000.00 t2000
chk "touch -t 2000 t2000"
# 2038 年を越える。UFS1 の時刻は 32bit。
printf 'new\n' > t2040; touch -t 204001010000.00 t2040
chk "printf new\n > t2040; touch -t 204001010000.00 t20"
if [ "$(id -u)" = 0 ]; then
	printf 'o\n' > owned; chown 1234:5678 owned
	chk "chown 1234:5678 owned"
	printf 'o\n' > bigid; chown 70000:70000 bigid
	chk "chown 70000:70000 bigid"
fi
