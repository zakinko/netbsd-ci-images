#!/bin/sh
# $1 の下を一行一項目で書き出す。OS が違っても同じ形になるようにしてある。
#   M|mode|nlink|size|mtime|uid|gid|path   (directory の nlink と size は -)
#   L|path|target
#   H|sha256|path
set -e
cd "$1"
case $(uname -s) in
Linux)	fmt='-c'; spec='%A|%h|%s|%Y|%u|%g|%n' ;;
*)	fmt='-f'; spec='%Sp|%l|%z|%m|%u|%g|%N' ;;
esac
{
	find . ! -name . -exec stat $fmt "$spec" {} + |
	awk -F'|' 'BEGIN{OFS="|"} { if ($1 ~ /^d/) { $2 = "-"; $3 = "-" } print "M", $0 }'
	find . -type l | while IFS= read -r l; do
		printf 'L|%s|%s\n' "$l" "$(readlink "$l")"
	done
	find . -type f -exec openssl dgst -sha256 -r {} + |
	sed -e 's/^\([0-9a-f]*\) \*\{0,1\}/H|\1|/'
} | LC_ALL=C sort
