#!/bin/sh
# 書いていない所が 0 で読めるかを、EOF を越えて伸ばす道ごとに試す。
#   zerofill.sh <dir on the fs under test> <dir on a reference fs>
# fs/ufs は新しい block の EOF より先の fragment を device の上では
# 0 にしない (ufs-08)。書き手には new の buffer として渡し、i_size が
# 飛び越して伸びるときにだけ 0 にする。どちらかが漏れると、消した
# ファイルの中身が見える。そこで先に空きを乱数で汚し、同じ操作を参照の
# fs にもして、page cache からと drop_caches の後との二度、全 byte を
# 突き合わせる。一行に一つ「case: cached N, reread N」を出す (N は
# 違う byte の数、0 が正しい)。
set -u
t=$1 r=$2
mkdir -p $t $r

dirty() {	# 空きを乱数で埋めてから消す
	dd if=/dev/urandom of=$t/.junk bs=1M count=32 2>/dev/null
	sync; rm -f $t/.junk; sync
}
drop() { sync; echo 3 > /proc/sys/vm/drop_caches; }
ndiff() { cmp -l "$1" "$2" 2>/dev/null | wc -l; }
run() {	# name, then a command run once in each directory as "$d"
	name=$1; shift
	dirty
	for d in $r $t; do
		rm -f $d/f
		(cd $d && eval "$*") > /dev/null 2>&1
	done
	sync
	a=$(ndiff $r/f $t/f)
	[ "$(stat -c %s $r/f)" = "$(stat -c %s $t/f)" ] || a="$a (size $(stat -c %s $t/f) != $(stat -c %s $r/f))"
	drop
	b=$(ndiff $r/f $t/f)
	printf '%s: cached %s, reread %s\n' "$name" "$a" "$b"
	rm -f $r/f $t/f
}

# 乱数は d ごとに違うので、書く中身は固定の模様にする。
pat() { yes "$1" | head -c $2; }
w() { pat "$3" $2 | dd of=f bs=1 seek=$1 conv=notrunc 2>/dev/null; }

run "next page, past EOF"        'w 0 4096 a; w 6000 1 b'
run "same page, past EOF"        'w 0 100 a; w 3000 1 b'
run "next block, past EOF"       'w 0 5000 a; w 70000 1 b'
run "truncate up, same block"    'w 0 100 a; truncate -s 7000 f'
run "truncate up, far"           'w 0 5000 a; truncate -s 200000 f'
run "truncate down then up"      'w 0 20000 a; truncate -s 3000 f; truncate -s 20000 f'
run "append 1000 x 37 bytes"     'for i in $(seq 1000); do pat c 37 >> f; done'
run "hole filled in the middle"  'truncate -s 1048576 f; w 524288 4096 d'
run "hole, unaligned write"      'truncate -s 300000 f; w 100003 777 e'
run "O_SYNC, past EOF"           'pat a 4096 | dd of=f bs=4096 oflag=sync 2>/dev/null; pat b 1 | dd of=f bs=1 seek=6000 conv=notrunc oflag=sync 2>/dev/null'
run "rewrite past EOF after shrink" 'w 0 8192 a; truncate -s 1000 f; w 5000 10 b'
# mmap は EOF のある page の残りを見せ、POSIX はそこを 0 と定める。
# 100 byte 書いて device から読み直した page の、100 から先を数える。
tp=/var/tmp/tailpeek
cc -O2 -o $tp "$(dirname "$0")/tailpeek.c"
dirty
pat a 100 > $t/f
drop
printf 'mmap past EOF in the EOF page: %s non-zero bytes\n' "$($tp $t/f)"
rm -f $t/f $tp
