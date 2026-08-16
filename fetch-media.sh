#!/bin/sh
# 媒体を取ってくる。取得元をどこにも残さない。
#
#   sh fetch-media.sh --for <disk_images からの相対パス>
#   sh fetch-media.sh --list <取得元のディレクトリ>
#
#   例: sh fetch-media.sh --for SunOS/openssh-5.4p1.tar.lz
#
# 取得元は二つに分けて渡す。どちらもリポジトリには書かない。
#
#   MEDIA_BASE        取得元の入口 (環境から。CI では secret)
#   media-paths.conf  置き場と取得元ディレクトリの対応表 (.gitignore 済み。
#                     CI では secret から書き出す。見本は
#                     media-paths.conf.example)
#
# なぜそこまでするのか。public なリポジトリでは、スクリプトも実行ログも
# 誰でも読める。再配布の許諾が無いものについて、取得元と対象を公開の記録に
# 残す理由がない。そこで
#
#   - 入口も階層もリポジトリに書かない
#   - curl の進捗表示 (URL が出る) を止める
#   - curl の失敗メッセージからも伏せる
#   - GitHub Actions では ::add-mask:: で入口・ホスト名・階層を伏字にさせる
#   - 表示するのはファイル名と大きさだけ
#
# 落としたものは MEDIA_DIR に溜める。既にあるものは取り直さない。途中で
# 切れたものは -C - で続きから取る。
#
# 取ったものを artifact や release に上げないこと。伏せる意味が無くなる。

set -eu

BASE=${BASE:-$(cd "$(dirname "$0")" && pwd)}
MEDIA_DIR=${MEDIA_DIR:-$BASE/disk_images}
MAP=${MEDIA_PATHS:-$BASE/media-paths.conf}
MEDIA_BASE=${MEDIA_BASE:-}

[ -n "$MEDIA_BASE" ] || {
	echo "$0: MEDIA_BASE が空。取得元は環境から渡すこと。" >&2
	echo "   リポジトリには書かない (public なので取得元が残る)。" >&2
	exit 1
}

HOST=$(echo "$MEDIA_BASE" | sed -e 's|^[a-z]*://||' -e 's|/.*||')

# GitHub Actions に伏字を頼む。ここで渡した文字列は、以後どこから出ても
# *** に置き換わる。階層も渡す。
mask() {
	[ "${GITHUB_ACTIONS:-}" = true ] || return 0
	[ -n "$1" ] || return 0
	echo "::add-mask::$1"
}
mask "$MEDIA_BASE"
mask "$HOST"

# 取得元が混じった出力を伏せる。curl の失敗メッセージ対策。
hide() {
	sed -e "s|$MEDIA_BASE|<media>|g" -e "s|$HOST|<media>|g"
}

decode() {
	python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.argv[1]))' "$1"
}

# 対応表から取得元のディレクトリを引く。
lookup() {
	[ -s "$MAP" ] || {
		echo "$0: $MAP が無い。media-paths.conf.example を見よ。" >&2
		return 1
	}
	awk -v want="$1" '/^[^#]/ && $1 == want { $1 = ""; sub(/^[ \t]+/, ""); print; exit }' "$MAP"
}

MODE=${1:-}
case $MODE in
--for)
	REL=${2:-}
	[ -n "$REL" ] || { echo "usage: $0 --for <相対パス>" >&2; exit 1; }
	DIR=$(lookup "$REL") || exit 1
	[ -n "$DIR" ] || { echo "$0: $REL の取得元が対応表に無い" >&2; exit 1; }
	mask "$DIR"
	mask "$(decode "$DIR")"
	NAME=$(basename "$REL")
	OUT=$MEDIA_DIR/$REL
	if [ -s "$OUT" ]; then
		echo "済み  $NAME  ($(wc -c < "$OUT" | tr -d ' ') バイト)"
		exit 0
	fi
	mkdir -p "$(dirname "$OUT")"
	echo "取る  $NAME"
	# 取りに行く名前は符号化前のものを使う。保存する名前は復号したもの。
	if curl -fsS -m 7200 -C - -o "$OUT.part" \
	    "$MEDIA_BASE/$DIR/$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$NAME")" 2>&1 | hide; then
		mv "$OUT.part" "$OUT"
		echo "完了  $NAME  ($(wc -c < "$OUT" | tr -d ' ') バイト)"
	else
		echo "!! $NAME を取れなかった" >&2
		rm -f "$OUT.part"
		exit 1
	fi
	;;
--list)
	DIR=${2:-}
	[ -n "$DIR" ] || { echo "usage: $0 --list <ディレクトリ>" >&2; exit 1; }
	mask "$DIR"
	curl -fsS -m 120 "$MEDIA_BASE/$DIR/" 2>&1 | hide |
		sed -n 's/.*href="\([^"?][^"]*\)".*/\1/p' |
		grep -v '^[a-z]*://' | grep -v '^/' |
		while read -r e; do decode "$e"; done
	;;
*)
	echo "usage: $0 --for <相対パス> | --list <ディレクトリ>" >&2
	exit 1
	;;
esac
