# build-image.sh と gen-targets.sh が共通で使う引き当て。
# 単独では動かない。. で読むこと。

# ports.conf の一行を引く。
#
#   port_field <port> <列番号>
#
# 列番号は 1=port 2=arch 3=vmm 4=emu 5=mem 6=pkg。無い port なら空。
port_field() {
	awk -v p="$1" -v n="$2" '$1 == p { print $n; exit }' "$BASE/ports.conf"
}

port_list() {
	awk '/^[a-z]/ { print $1 }' "$BASE/ports.conf"
}

# その URL が実在するか。中身は取らない。
#
# 配布ツリーは巨大なので、-I で頭だけ見る。ディレクトリでも 200 が返る。
url_exists() {
	curl -fsSL -I -m 30 -o /dev/null "$1" 2>/dev/null
}

# port と release から配布ツリーの URL を出す。無ければ空を返して 1。
#
# 三つの厄介がある。
#
#   9.0 より前は本ミラーから外れて archive にある。ただし 9.x は両方に
#   あったりなかったりするので、決め打ちにせず両方当たる。
#
#   hppa は 6.0 より前は hp700 という名前だった。同じ port の同じものが
#   途中で名前を変えただけなので、両方見て在るほうを使う。
#
#   evbarm と riscv は release ツリーに無い。11.0 の配布物を見ると
#   evbarm-aarch64 は ISO しか無く、armv7/arm64/riscv64 の展開済み
#   イメージ (anita が使うもの) は daily にしか置かれていない。
#   release として指定されたときは何も見つからず、その組み合わせは
#   単に飛ばされる。daily を組みたいときは release の代わりに
#   netbsd-10 のようなブランチ名を渡す。
dist_url() {
	_port=$1
	_rel=$2
	_arch=$(port_field "$_port" 2)
	_tree=$(port_field "$_port" 7)

	case $_rel in
	HEAD|netbsd-*)
		[ "$_tree" = daily ] || return 1
		_u="https://nycdn.netbsd.org/pub/NetBSD-daily/$_rel/latest/$_arch/"
		url_exists "$_u" && { echo "$_u"; return 0; }
		return 1
		;;
	esac
	# 展開済みイメージから起こす port は daily にしかない。古い release
	# ツリーにも evbarm/ はあるが、中身は当時の別物で anita は入れられない。
	[ "$_tree" = release ] || return 1

	case $_port in
	hppa)	_dirs="hppa hp700" ;;
	*)	_dirs=$_port ;;
	esac

	for _d in $_dirs; do
		for _b in https://cdn.netbsd.org/pub/NetBSD/ \
			  https://archive.netbsd.org/pub/NetBSD-archive/; do
			_u="${_b}NetBSD-$_rel/$_d/"
			url_exists "$_u" && { echo "$_u"; return 0; }
		done
	done
	return 1
}

# 入れるセットを決める。
#
# 版によって在るものが違う。kern-GENERIC は 1.4 から (それ以前は kern)、
# modules は 5.0 から、xetc は 2.0 から、といった具合で、無いものを
# anita に渡すと知らない名前だと言って止まる。机上で表を作ると必ず
# どこかで外すので、その版の binary/sets/ を見て在るものだけ選ぶ。
#
# X を入れるのは、pkgsrc の X11 を使うものが /usr/X11R? を見に行くため。
# 画面のいらない検査でも Xvfb は xserver に入っている。
dist_sets() {
	_url=$1
	_want="kern-GENERIC kern modules base etc comp man misc text
	       xbase xcomp xetc xfont xserver"

	# 末尾の / を落としてから継ぎ足す。dist_url は / で終わる URL を返すので、
	# そのまま継ぐと //binary/sets/ になり、archive はそれを 404 で返す。
	# 一覧が取れないと --sets が空のまま anita に渡り、anita の既定の一覧で
	# 入れようとして、その版に無いセットで転ける。
	_ls=$(curl -fsSL -m 60 "${_url%/}/binary/sets/" 2>/dev/null |
		sed -n 's/.*href="\([^"]*\)".*/\1/p')
	[ -n "$_ls" ] || return 1

	_out=
	for _s in $_want; do
		# 拡張子は .tgz と .tar.xz の二通り。1.x には分割された
		# base.aa のような置き方もあるが、そちらは sysinst 以前の
		# 世代なので anita では入らない。
		if echo "$_ls" | grep -q "^$_s\.\(tgz\|tar\.xz\)$"; then
			_out="${_out:+$_out,}$_s"
		fi
	done
	# kern-GENERIC と kern は同じ役目なので、両方在れば新しいほうだけ。
	echo "$_out" | sed 's/kern-GENERIC,kern,/kern-GENERIC,/'
}

# 1.5.3 のような版番号を数で比べられるようにする。1.5.3 -> 1005003
relnum() {
	echo "$1" | awk -F. '{ printf "%d%03d%03d\n", $1, $2, $3 }'
}
