#!/bin/sh
# 読み込まれたモジュールの中で、call の次の命令の番地の下 12 bit が
# 与えた値になる場所を挙げる。
#   modret.sh <low12 の 16 進> <module>...
# run 41539207653 の panic は戻り番地が 0xffffffffa05f7a79 と読めたが、
# モジュールのロード番地が残っておらず関数まで引けなかった。ロード番地は
# ページ単位なので、下 12 bit は同じモジュールなら起動ごとに変わらない。
want=$1; shift
for m in "$@"; do
	f=$(modinfo -F filename $m 2>/dev/null)
	[ -d /sys/module/$m/sections ] || continue
	# 自分で insmod したものは modinfo の path と違うので、呼ぶ側が
	# MODRET_KO に置く。xfs は .ko.xz で配られている。
	eval ko=\${MODRET_KO_$m:-$f}
	case $ko in
	*.xz) xz -dc $ko > /var/tmp/modret.ko; ko=/var/tmp/modret.ko ;;
	esac
	for s in /sys/module/$m/sections/.text*; do
		sec=${s##*/}
		base=$(cat $s)
		echo "$m $sec base $base"
		objdump -dr --no-show-raw-insn -j $sec $ko | gawk -v m=$m -v sec=$sec \
		    -v base=$base -v want=$want '
		/^[0-9a-f]+ <.*>:$/ { fn = $2; pending = 0; next }
		/^\t+[0-9a-f]+: R_/ { if (pending) rel = $3; next }
		/^ +[0-9a-f]+:\t/ {
			a = strtonum("0x" substr($1, 1, length($1) - 1))
			if (pending && and(strtonum(base) + a, 4095) == strtonum("0x" want))
				print "  " m " " sec " " fn " returns to +" sprintf("%#x", a) " after call " rel
			pending = ($2 ~ /^call/); rel = $3
		}'
	done
done
