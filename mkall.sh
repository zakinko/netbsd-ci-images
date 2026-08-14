#!/bin/sh
# 一覧を順に組む。root で:  sh mkall.sh
#
# 既に .img.gz がある組み合わせは飛ばすので、途中で止めても掛け直せる。
# 焼き直したいものは .img.gz を消してから走らせること。
#
# セットは $BASE/sets/<arch>-<release>/ に残る。同じ版を組み直すときは
# 再取得されない。全部で 3 GB ほど。
#
# ログは $BASE/log/<arch>-<release>.log。失敗しても次へ進み、最後に
# まとめて報告する。一つ転けるたびに全部止まるほうが困る。

BASE=${BASE:-$(cd "$(dirname "$0")" && pwd)}
LIST=${LIST:-"
i386 11.0
i386 10.1
i386 9.4
i386 8.3
i386 7.2
i386 6.1.5
i386 5.2.3
i386 4.0.1
i386 3.1
i386 2.1
i386 1.6.2
i386 1.5.3
amd64 11.0
amd64 10.1
amd64 9.4
amd64 8.3
amd64 7.2
amd64 6.1.5
amd64 5.2.3
amd64 4.0.1
amd64 3.1
amd64 2.1
sparc64 11.0
"}

mkdir -p $BASE/log
OK=; NG=; SKIP=

# 一覧はファイル経由で読む。パイプで while に流すと部分シェルになり、
# 集計した変数が最後に残らない。
echo "$LIST" > /tmp/mkall.list

while read arch rel; do
	[ -n "$arch" ] || continue
	name=$arch-$rel
	if [ -s $BASE/$name.img.gz ]; then
		echo "=== $name  済み (飛ばす) ==="
		SKIP="$SKIP $name"
		continue
	fi
	echo "=== $name  組む ==="
	if sh $BASE/mkimg.sh $arch $rel > $BASE/log/$name.log 2>&1; then
		echo "    OK  $(ls -l $BASE/$name.img.gz | awk '{print $5}') bytes"
		OK="$OK $name"
	else
		echo "    NG  $BASE/log/$name.log の末尾:"
		tail -5 $BASE/log/$name.log | sed 's/^/      /'
		NG="$NG $name"
		# 途中で落ちると vnd を掴んだままのことがある。次に響くので外す。
		umount ${MNT:-/mnt/nbimg} 2>/dev/null
		vnconfig -u ${VND:-vnd3} 2>/dev/null
		rm -f $BASE/$name.img
	fi
done < /tmp/mkall.list

echo
echo "=== まとめ ==="
echo "組めた   :${OK:- なし}"
echo "飛ばした :${SKIP:- なし}"
echo "駄目     :${NG:- なし}"
[ -z "$NG" ]
