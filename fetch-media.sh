#!/bin/sh
# 媒体を取ってくる。取得元を実行ログに残さない。
#
#   sh fetch-media.sh <ディレクトリ>              一覧を見る
#   sh fetch-media.sh <ディレクトリ> <glob>...    取る
#
#   例: sh fetch-media.sh sunos/sparc
#       sh fetch-media.sh irix 'irix-6.5*'
#
# 取得元は MEDIA_BASE で渡す。**既定値は置かない。** ここに書けば public な
# リポジトリに取得元を書いたことになり、伏せる意味が無くなる。CI では
# secret に入れて渡すこと。GitHub は secret の値をログで伏字にするので、
# こちらの手当てと二重になる。
#
# なぜ隠すのか。public なリポジトリでは実行ログを誰でも読めます。媒体その
# ものは runner の破棄と一緒に消えますが、ログに残った URL は残り続けます。
# 再配布の許諾が無いものについて、取得元と対象を公開の記録に残す理由は
# ありません。そこで
#
#   - curl の進捗表示 (URL が出る) を止める
#   - curl の失敗メッセージから取得元を伏せる
#   - GitHub Actions では ::add-mask:: で URL そのものを伏字にさせる
#   - 表示するのはファイル名と大きさだけ
#
# 落としたものは MEDIA_DIR に溜めます。既にあるものは取り直しません。
# 途中で切れたものは -C - で続きから取ります。
#
# 取ったものを artifact や release に上げないこと。ログを伏せる意味が
# 無くなります。

set -eu

BASE=${BASE:-$(cd "$(dirname "$0")" && pwd)}
MEDIA_DIR=${MEDIA_DIR:-$BASE/disk_images}
MEDIA_BASE=${MEDIA_BASE:-}
[ -n "$MEDIA_BASE" ] || {
	echo "$0: MEDIA_BASE が空。取得元は環境から渡すこと。" >&2
	echo "   リポジトリには書かない (public なので取得元が残る)。" >&2
	echo "   CI では secret に置き、手元では ~/.profile などから。" >&2
	exit 1
}

DIR=${1:-}
[ -n "$DIR" ] || { echo "usage: $0 <ディレクトリ> [glob...]" >&2; exit 1; }
shift || true

# GitHub Actions に伏字を頼む。ここで渡した文字列は、以後どこから出ても
# *** に置き換わる。
if [ "${GITHUB_ACTIONS:-}" = true ]; then
	echo "::add-mask::$MEDIA_BASE"
	# ホスト名だけでも出所が分かるので、それも伏せる。
	echo "::add-mask::$(echo "$MEDIA_BASE" | sed -e 's|^[a-z]*://||' -e 's|/.*||')"
fi

# 取得元が混じった出力を伏せる。curl の失敗メッセージ対策。
hide() {
	sed -e "s|$MEDIA_BASE|<media>|g" \
	    -e "s|$(echo "$MEDIA_BASE" | sed -e 's|^[a-z]*://||' -e 's|/.*||')|<media>|g"
}

# %20 などを戻す。表示と保存に使う名前は復号したもの、取りに行くのは
# 復号前のもの。
decode() {
	python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.argv[1]))' "$1"
}

OUT=$MEDIA_DIR/$DIR
mkdir -p "$OUT"

# 一覧を読む。ディレクトリは末尾が / なので分けておく。
LIST=$(curl -fsS -m 120 "$MEDIA_BASE/$DIR/" 2>&1 | hide |
	sed -n 's/.*href="\([^"?][^"]*\)".*/\1/p' |
	grep -v '^[a-z]*://' | grep -v '^/' || true)
[ -n "$LIST" ] || { echo "$0: $DIR の一覧が読めなかった" >&2; exit 1; }

if [ $# -eq 0 ]; then
	echo "=== $DIR"
	for e in $LIST; do
		printf '  %s\n' "$(decode "$e")"
	done
	exit 0
fi

for e in $LIST; do
	case $e in */) continue ;; esac
	name=$(decode "$e")

	want=no
	for p in "$@"; do
		# shellcheck disable=SC2254
		case $name in $p) want=yes; break ;; esac
	done
	[ "$want" = yes ] || continue

	if [ -s "$OUT/$name" ]; then
		echo "済み  $name  ($(wc -c < "$OUT/$name" | tr -d ' ') バイト)"
		continue
	fi

	echo "取る  $name"
	# -sS で進捗表示 (URL が出る) を止め、-C - で続きから。
	if curl -fsS -m 7200 -C - -o "$OUT/$name.part" "$MEDIA_BASE/$DIR/$e" 2>&1 | hide; then
		mv "$OUT/$name.part" "$OUT/$name"
		echo "完了  $name  ($(wc -c < "$OUT/$name" | tr -d ' ') バイト)"
	else
		echo "!! $name を取れなかった" >&2
		rm -f "$OUT/$name.part"
		exit 1
	fi
done
