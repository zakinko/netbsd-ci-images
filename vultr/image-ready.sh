#!/bin/sh
# Vultr へ渡すイメージ URL を、渡す前に見る。
#
#   sh image-ready.sh <URL>
#
# Vultr の取り込みが失敗するとき、Vultr は何も言わない。snapshot は pending に
# なった直後に消え、以後 API は Invalid snapshot ID を返すだけで、取り込みに
# 失敗したとは言わない。だから落ちる条件は先に自分で見るしかない。README に
# 四つ書いてあるが、書いてあっても渡す瞬間には読んでいない。この script が
# 代わりに読む。
#
#   1. 302 で飛ぶ URL          Vultr は追わない
#   2. 2 GiB を超える asset    GitHub の release に上がらない
#   3. gz で固めたもの         Vultr は展開しない
#   4. 生イメージでないもの    書き戻しても起動しない
#
# 通っても「起動する」ことにはならない。ここで見るのは渡す前に分かる分だけ。
set -eu

url=${1:-}
[ -n "$url" ] || { echo "usage: $0 <URL>" >&2; exit 2; }

fail=0
say() { printf '%-28s %s\n' "$1" "$2"; }
bad() { say "$1" "NG  $2"; fail=1; }

# 1. リダイレクト。多段のこともあるので -L で最後まで追う。
final=$(curl -sIL -o /dev/null -w '%{url_effective}' "$url")
if [ "$final" = "$url" ]; then
	say リダイレクト "無し"
else
	# 署名がクエリに入るので host だけ出す。
	bad リダイレクト "$(echo "$final" | sed 's|https://\([^/]*\)/.*|\1|') へ飛ぶ。解決してから渡すこと (snapshot-from-url.sh がやる)"
fi

code=$(curl -sIL -o /dev/null -w '%{http_code}' "$url")
[ "$code" = 200 ] || bad 取得 "HTTP $code"

# 2. 大きさ。GitHub の release は asset 一つ 2 GiB まで。
size=$(curl -sIL -o /dev/null -w '%{size_download}\n%{header_json}' "$url" 2>/dev/null |
	python3 -c 'import json,sys
sys.stdin.readline()
try:
    h = json.loads(sys.stdin.read())
    print(int(h.get("content-length", ["0"])[-1]))
except Exception:
    print(0)')
if [ "${size:-0}" -eq 0 ]; then
	say 大きさ "分からなかった (Content-Length 無し)"
elif [ "$size" -gt 2147483648 ]; then
	bad 大きさ "$size bytes。2 GiB を超えている"
else
	say 大きさ "$size bytes"
fi

# 3 と 4. 頭の 512 バイトだけ取って中身を見る。
head512=$(curl -sL --max-time 60 -r 0-511 "$url" | od -An -tx1 -v | tr -d ' \n')
case "$head512" in
	1f8b*) bad 中身 "gzip。Vultr は展開しないので生のまま置くこと";;
	425a68*) bad 中身 "bzip2。生のまま置くこと";;
	28b52ffd*) bad 中身 "zstd。生のまま置くこと";;
	*)
		# MBR か GPT の保護 MBR なら 510-511 が 55 aa。
		# 16 進なので 1 バイトが 2 文字。末尾の 2 バイトを数えずに取る。
		tail4=${head512#"${head512%????}"}
		if [ "$tail4" = "55aa" ]; then
			say 中身 "生イメージ (先頭に MBR がある)"
		else
			bad 中身 "先頭 512 バイトが MBR に見えない (末尾 ${tail4}、55aa のはず)"
		fi
		;;
esac

[ $fail -eq 0 ] && echo "渡してよい" || echo "渡すな"
exit $fail
