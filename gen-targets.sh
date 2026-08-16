#!/bin/sh
# 組む値のある <port>-<release> を数え上げる。
#
#   sh gen-targets.sh                 全部
#   sh gen-targets.sh i386 sparc64    port を絞る
#   RELEASES="10.1 11.0" sh gen-targets.sh
#
# 一行に一つ、i386-10.1 のように出す。port の名前に - は入らないので、
# 最初の - までが port、残りが release になる。
#
# 実在する組み合わせだけを出す。どの port がどの版から在るか (amd64 は
# 2.0 から、landisk は 4.0 から、hppa は 6.0 まで hp700 だった) を手で
# 表にすると必ずどこかで外すので、ミラーの一覧をそのまま読む。
#
# 「実在する」は「配布ツリーがある」であって「組める」ではない。sysinst
# そのものが 1.3 からなので 1.2.1 以前は anita では入らないし、入っても
# その版のカーネルが QEMU の周辺機器を扱えるとは限らない。どれが通るのかは
# 実際に組んでみるまで分からないので、ここでは候補を出すだけにする。

set -eu

BASE=${BASE:-$(cd "$(dirname "$0")" && pwd)}
. "$BASE/common.sh"

PORTS=${*:-$(port_list)}

# 版の一覧。9.0 より前は本ミラーから外れて archive にある。
#
# 後ろに daily のブランチを足してある。展開済みイメージから起こす port
# (evbarm evbarm64 riscv64) は release ツリーに配布物が無く、ここからしか
# 組めないため。番号の付いた版だけを見ていると、この三つが一つも出ない。
list_releases() {
	for b in https://cdn.netbsd.org/pub/NetBSD/ \
		 https://archive.netbsd.org/pub/NetBSD-archive/; do
		curl -fsSL -m 60 "$b" 2>/dev/null |
			sed -n 's/.*href="NetBSD-\([0-9][^/"]*\)\/".*/\1/p'
	done | sort -u -t. -k1,1n -k2,2n -k3,3n
	echo netbsd-9
	echo netbsd-10
	echo netbsd-11
}

RELEASES=${RELEASES:-$(list_releases)}
[ -n "$RELEASES" ] || { echo "$0: 版の一覧が取れなかった" >&2; exit 1; }

for rel in $RELEASES; do
	# その版のツリーに何が置かれているかを一度だけ読む。port ごとに
	# 当たると port 数 x 版数 の問い合わせになって効かない。
	case $rel in
	HEAD|netbsd-*)
		# daily はブランチごとに MACHINE-MACHINE_ARCH で並んでいる。
		# release ツリーに無い evbarm と riscv はこちらにしかない。
		dirs=$(curl -fsSL -m 60 \
			"https://nycdn.netbsd.org/pub/NetBSD-daily/$rel/latest/" 2>/dev/null |
			sed -n 's/.*href="\([^"/]*\)\/".*/\1/p')
		col=2
		;;
	*)
		dirs=
		for b in https://cdn.netbsd.org/pub/NetBSD/ \
			 https://archive.netbsd.org/pub/NetBSD-archive/; do
			dirs=$(curl -fsSL -m 60 "${b}NetBSD-$rel/" 2>/dev/null |
				sed -n 's/.*href="\([^"/]*\)\/".*/\1/p')
			[ -n "$dirs" ] && break
		done
		col=1
		;;
	esac
	[ -n "$dirs" ] || continue

	for port in $PORTS; do
		tree=$(port_field "$port" 7)
		[ -n "$tree" ] || continue
		# 展開済みイメージから起こす port は daily にしか置かれて
		# いない。古い release ツリーにも同じ名前のディレクトリは
		# あるが、anita が要るものは入っていない。
		if [ "$col" = 2 ]; then
			[ "$tree" = daily ] || continue
			want=$(port_field "$port" 2)
		else
			[ "$tree" = release ] || continue
			want=$port
		fi
		# hppa は 6.0 より前は hp700。同じものが名前を変えただけ。
		[ "$port" = hppa ] && want="hppa hp700"
		for w in $want; do
			if echo "$dirs" | grep -qx "$w"; then
				echo "$port-$rel"
				break
			fi
		done
	done
done
