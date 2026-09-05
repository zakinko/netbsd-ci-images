#!/bin/sh
# 公開 URL に置いた raw ディスクイメージを Vultr の snapshot として取り込む。
# ansible を通さずに API を直に叩くとき用。
#
#   VULTR_API_KEY=... sh snapshot-from-url.sh <URL> <description>
#
# 手でやると必ず忘れるのが URL の解決で、忘れると何も言わずに失敗する。
# Vultr は渡された URL を**自分で**取りに行くが、302 を追わない。GitHub の
# release は署名付きの別ホストへ飛ばすので、そのままの URL を渡すと取り込みは
# pending になった直後に黙って消され、以後 API は Invalid snapshot ID を返す。
# エラーは取り込み失敗を指さないので、待っている側からは固まったようにしか
# 見えない。up.yml が渡す前に curl で解決しているのはこのためで、この script
# も同じことをする。
#
# 署名付きのクエリ文字列そのものは通る。署名は一時間ほどで切れるが、Vultr は
# 受け取った直後に取りに行くので間に合う。
#
# 鍵は表に出さないこと。macOS なら
#   VULTR_API_KEY="$(security find-generic-password -a "$USER" -s vultr-api-key -w)"
set -eu

url=${1:-}
desc=${2:-}
[ -n "$url" ] && [ -n "$desc" ] || {
	echo "usage: VULTR_API_KEY=... $0 <URL> <description>" >&2
	exit 2
}
[ -n "${VULTR_API_KEY:-}" ] || { echo "$0: VULTR_API_KEY が無い" >&2; exit 2; }

api() {
	# 鍵は引数に置かない (ps に出る)。-H を標準入力から渡す。
	method=$1; path=$2; shift 2
	curl -s -X "$method" -H @/dev/fd/3 -H 'Content-Type: application/json' \
		"https://api.vultr.com/v2$path" "$@" 3<<-HDR
	Authorization: Bearer $VULTR_API_KEY
	HDR
}

# 多段のこともあるので -L で最後まで追い、辿り着いた先を取る。curl の
# %{redirect_url} は一段しか見ない。解決した URL は image-ready.sh に通す。
echo "URL を解決する"
final=$(curl -sIL -o /dev/null -w '%{url_effective}' "$url")
case "$final" in
	https://*) ;;
	*) echo "$0: 解決できなかった ($url)" >&2; exit 1;;
esac
if [ "$final" != "$url" ]; then
	# 署名がクエリに入るので、host だけ出す。
	echo "  -> $(echo "$final" | sed 's|https://\([^/]*\)/.*|\1|') へ飛んでいた"
fi

# 渡す前に見る。ここを通らずに API を叩く道が残っているうちは、いつか誰かが
# gz か 2 GiB 超えを渡して、また黙って消えるのを眺めることになる。
if ! sh "$(dirname "$0")/image-ready.sh" "$final"; then
	echo "$0: 渡す前の確認で止めた" >&2
	exit 1
fi

body=$(printf '%s' "$final" | python3 -c 'import json,sys; print(json.dumps({"url": sys.stdin.read(), "description": sys.argv[1]}))' "$desc")
id=$(api POST /snapshots/create-from-url -d "$body" |
	python3 -c 'import json,sys; print(json.load(sys.stdin).get("snapshot",{}).get("id",""))')
[ -n "$id" ] || { echo "$0: 取り込みを頼めなかった" >&2; exit 1; }
echo "snapshot $id  取り込み中"

# 取りに行けなかった snapshot は Vultr が黙って消す。消えたものを待ち続けない。
i=0
while [ $i -lt 60 ]; do
	sleep 20
	i=$((i + 1))
	out=$(api GET "/snapshots/$id")
	status=$(printf '%s' "$out" |
		python3 -c 'import json,sys; s=json.load(sys.stdin).get("snapshot"); print(s.get("status") if s else "gone")')
	case "$status" in
		complete)
			printf '%s' "$out" | python3 -c 'import json,sys
s = json.load(sys.stdin)["snapshot"]
print("出来た %s  %s bytes (圧縮後 %s)" % (s["id"], s["size"], s["compressed_size"]))'
			exit 0;;
		gone)
			echo "$0: snapshot が消えた。Vultr がイメージを取りに行けていない。" >&2
			echo "  渡した先: $(echo "$final" | sed 's|https://\([^/]*\)/.*|\1|')" >&2
			exit 1;;
	esac
done
echo "$0: 20 分待っても $status のままだった ($id)" >&2
exit 1
