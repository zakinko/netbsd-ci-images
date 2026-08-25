#!/bin/sh
# イメージを起動し、ssh で入れるようになるまで待つ。
#
#   sh runvm.sh <port>-<release> [ssh ポート]
#   例: sh runvm.sh i386-10.1
#       sh runvm.sh macppc-9.4 2223
#
# 繋ぎ方は同じ名前の .qemu から読む。イメージと食い違うと root が見つからず
# 起動しないので、ここで決め打ちにはしない。port によっては、カーネルや
# 起動用の CD、device tree をホストから渡す必要がある。それらも .qemu に
# 書いてあるとおりに置き換える。
#
# 鍵はイメージに焼かれていない。起動のたびにゲストの seed_key が
# http://10.0.2.2:<SEED_PORT>/authorized_keys を取りに来るので、ここで
# 使い捨ての鍵対を作って配る。おかげで secret も固定の鍵も要らない。
#
# イメージは -snapshot で開く。書き込みは捨てられ、落としてきた qcow2 は
# そのまま次の実行にも使える。中身を残したいときは KEEP=1 を渡す。
#
# 止めるときは stopvm.sh を使うこと。QEMU モニタの quit は電源を引き抜くの
# と同じで、FFS が壊れて次回 fsck で長時間待たされるか、起動しなくなる。
#
# gxemul と simh の port は扱わない。どちらにも user networking も port
# forward も無く、ホストから ssh で入る口がそもそも作れない。組んだときに
# anita が login まで出したことは確かめてあるので、あとはコンソールで
# 使うことになる。動かし方は表示する。

set -eu

NAME=$1
# ssh のポート。.qemu には NetBSD の port の名前を PORT= で書いてあるので、
# 同じ名前を使うと読み込んだ時点で潰される。実際 macppc のイメージで
# hostfwd が tcp:127.0.0.1:macppc-:22 になった。
SSHPORT=${2:-2222}

DIR=${DIR:-.}
META=$DIR/$NAME.qemu
# 既定は動かしている機械のコア数 (上限 4)。2 に固定していたので、4 vCPU の
# CI runner では半分しか使えていなかった。ゲストの中で pkgsrc が MAKE_JOBS を
# hw.ncpu から取るため、ここが効かないと build がそのぶん長くなる。
#
# 上限を 4 に置くのは、古い NetBSD ほど SMP の面倒を見た年数が短く、コアを
# 増やすほど当たりにくい不具合を踏む余地が増えるため。手元でもっと出したい
# ときは SMP= を渡す。
if [ -z "${SMP:-}" ]; then
	SMP=`(nproc || sysctl -n hw.ncpu || getconf _NPROCESSORS_ONLN) 2>/dev/null | head -1`
	case $SMP in ''|*[!0-9]*) SMP=2 ;; esac
	[ "$SMP" -gt 4 ] && SMP=4
fi
KEY=${KEY:-$DIR/$NAME.id}
SEED=$DIR/$NAME.seed
BASE=${BASE:-$(cd "$(dirname "$0")" && pwd)}

[ -s "$META" ] || { echo "$0: $META が無い"; exit 1; }
. "$META"
SEED_PORT=${SEED_PORT:-8123}
VMM=${VMM:-qemu}
MEM=${MEM:-2048}
EXTRAARGS=${EXTRAARGS:-}
ANSWERS=${ANSWERS:-}
SSHOPTS=${SSHOPTS:-}
SSH_OK=${SSH:-yes}

# イメージ本体。qcow2 をそのまま使う版と、生の .img.gz の版がある。
if [ -s "$DIR/$NAME.qcow2" ]; then
	IMG=$DIR/$NAME.qcow2
elif [ -s "$DIR/$NAME.img" ]; then
	IMG=$DIR/$NAME.img
elif [ -s "$DIR/$NAME.img.gz" ]; then
	echo "--- 展開 ---"
	gzip -dc "$DIR/$NAME.img.gz" > "$DIR/$NAME.img"
	IMG=$DIR/$NAME.img
else
	echo "$0: $NAME のイメージが無い"; exit 1
fi

subst() {
	echo "$1" | sed -e "s|@IMG@|$IMG|g" \
			-e "s|@KERNEL@|$DIR/$NAME.kernel|g" \
			-e "s|@BOOTISO@|$DIR/$NAME.bootiso|g" \
			-e "s|@DTB@|$DIR/$NAME.dtb|g" \
			-e "s|@MEM@|$MEM|g"
}

if [ "$VMM" != qemu ]; then
	echo "$0: $NAME は $VMM で動かす port なので、ここからは起動しない。"
	echo "   ホストから ssh で入る口が作れないため (user networking が無い)。"
	echo "   手で動かすなら:"
	echo "     $QEMU $(subst "$DISKARGS") $(subst "$EXTRAARGS")"
	exit 1
fi

command -v "$QEMU" > /dev/null 2>&1 || { echo "$0: $QEMU が無い"; exit 1; }

# 起動のたびに要るものが揃っているか。無いと root が見つからないのではなく、
# そもそもカーネルが起きない。
for f in KERNEL BOOTISO DTB; do
	case $EXTRAARGS in
	*"@$f@"*)
		case $f in
		KERNEL)		p=$DIR/$NAME.kernel ;;
		BOOTISO)	p=$DIR/$NAME.bootiso ;;
		DTB)		p=$DIR/$NAME.dtb ;;
		esac
		[ -s "$p" ] || { echo "$0: $p が要る (イメージと一緒に置くこと)"; exit 1; }
		;;
	esac
done

# ------------------------------------------------------------------
# 使い捨ての鍵を作って配る
mkdir -p "$SEED"
# 鍵は RSA にする。ed25519 は OpenSSH 6.5 (2014) からで、NetBSD 6 以前の
# sshd は authorized_keys に書いてあっても解さない。RSA はどの版でも通る。
if [ ! -s "$KEY" ]; then
	rm -f "$KEY" "$KEY.pub"
	ssh-keygen -q -t rsa -b 3072 -f "$KEY" -N '' -C "$NAME"
fi
cp "$KEY.pub" "$SEED/authorized_keys"

# 1.5.x の base の sshd は SSH2 で DSA しか喋らない。OpenSSH を組んで
# 差し替えられていれば RSA で入れるが、組めなかったときのために DSA も
# 一緒に配って、両方を提示する。ホストの ssh が新しすぎて DSA を作れない
# ときは黙って諦める (OpenSSH 10.0 で消えた)。
KEYARGS="-i $KEY"
case $SSHOPTS in
*ssh-dss*)
	if [ ! -s "$KEY.dsa" ]; then
		rm -f "$KEY.dsa" "$KEY.dsa.pub"
		ssh-keygen -q -t dsa -f "$KEY.dsa" -N '' -C "$NAME" 2>/dev/null ||
			echo "   (このホストの ssh-keygen は DSA を作れない)"
	fi
	if [ -s "$KEY.dsa.pub" ]; then
		cat "$KEY.dsa.pub" >> "$SEED/authorized_keys"
		KEYARGS="$KEYARGS -i $KEY.dsa"
	fi
	;;
esac

if command -v lsof > /dev/null 2>&1 &&
   lsof -nP -iTCP:"$SEED_PORT" -sTCP:LISTEN > /dev/null 2>&1; then
	echo "$0: ポート $SEED_PORT が塞がっている。" >&2
	echo "   ゲストの rc.d に焼き込んだ番号なので変えられない。" >&2
	echo "   別の VM が動いていないか確かめること。" >&2
	exit 1
fi
NOHUP=nohup
if command -v setsid > /dev/null 2>&1; then NOHUP="setsid nohup"; fi
# 配るのは authorized_keys だけなので、名前の付け替え (--alias) は要らない。
# それを使わないなら mirror-alias.py は http.server に --directory を渡した
# のと同じものなので、隣に無ければ標準のもので済ませる。この runvm.sh は
# 単体で持って行かれることがあり (pkgsrc-zakinko の CI は runvm.sh と
# stopvm.sh だけを raw で落とす)、そのとき隣には何も無い。
if [ -f "$BASE/mirror-alias.py" ]; then
	SERVE="python3 $BASE/mirror-alias.py --port $SEED_PORT --dir $SEED"
else
	SERVE="python3 -m http.server $SEED_PORT --bind 0.0.0.0 --directory $SEED"
fi
# shellcheck disable=SC2086
$NOHUP $SERVE > "$DIR/$NAME.seed.log" 2>&1 &
echo $! > "$DIR/$NAME.seedpid"

# ------------------------------------------------------------------
# x86 の guest なら KVM が使える。使えないと emulation で 10 倍以上遅い。
ACCEL=
case $QEMU in
qemu-system-i386|qemu-system-x86_64)
	if [ -w /dev/kvm ]; then ACCEL="-enable-kvm"; fi ;;
esac

# 古いイメージには DISKARGS が無いので DISKIF から組み立てて補う。
[ -n "${DISKARGS:-}" ] || \
	DISKARGS="-drive file=@IMG@,if=${DISKIF:-ide},format=raw,cache=unsafe"
DISK=$(subst "$DISKARGS")
EXTRA=$(subst "$EXTRAARGS")

# NIC の付け方。-netdev だけ渡して -device を付けないと netdev がどこにも
# 繋がらず、しかも -netdev を書いた時点で QEMU は既定の NIC を作らなくなる
# ので、guest はネットワーク無しで起動する (dhcpcd がアドレスを取れず、
# 鍵も取りに来られない)。model を指定しない -nic なら、その machine の
# 既定の NIC が付く。anita がインストール時に使ったのと同じものになる。
if [ -n "${NICDEV:-}" ]; then
	NET="-netdev user,id=n0,hostfwd=tcp:127.0.0.1:$SSHPORT-:22 -device $NICDEV,netdev=n0"
else
	NET="-nic user,hostfwd=tcp:127.0.0.1:$SSHPORT-:22"
fi

SNAP=-snapshot
if [ "${KEEP:-0}" = 1 ]; then SNAP=; fi

# コンソール。答える必要のある port だけ socket にして console.py を挟む。
# 普段はファイルに落とすだけで足りるし、挟むものが少ないほうが壊れにくい。
rm -f "$DIR/$NAME.console.log" "$DIR/$NAME.tty"
if [ -n "$ANSWERS" ]; then
	SERIAL="-serial unix:$DIR/$NAME.tty,server,nowait"
else
	SERIAL="-serial file:$DIR/$NAME.console.log"
fi

echo "=== $NAME を起動 (root=${ROOTDEV:-?} ssh=$SSHPORT${ACCEL:+ KVM}${SNAP:+ 使い捨て}) ==="
# shellcheck disable=SC2086
$QEMU $ACCEL $SNAP -m $MEM -smp $SMP \
	$DISK \
	$EXTRA \
	$NET \
	-display none \
	$SERIAL \
	-monitor "unix:$DIR/$NAME.mon,server,nowait" \
	-pidfile "$DIR/$NAME.pid" \
	-daemonize

if [ -n "$ANSWERS" ]; then
	set --
	# ANSWERS は 'regexp=>返事' を | で並べたもの。
	OIFS=$IFS; IFS='|'
	for a in $ANSWERS; do
		set -- "$@" --answer "$a"
	done
	IFS=$OIFS
	# shellcheck disable=SC2086
	$NOHUP python3 "$BASE/console.py" --socket "$DIR/$NAME.tty" \
		--log "$DIR/$NAME.console.log" "$@" \
		>> "$DIR/$NAME.seed.log" 2>&1 &
	echo $! > "$DIR/$NAME.consolepid"
fi

if [ "$SSH_OK" != yes ]; then
	echo "このイメージには ssh の口が無い。コンソール: $DIR/$NAME.console.log"
	exit 0
fi

# 入るための呼び出しを一箇所で決め、外にも書き出す。使う側が同じ指定を
# 書き写すと、片方だけ古くなって古い版で通らなくなる。
#
# 古い sshd は署名が ssh-rsa (SHA-1) しかなく、今の ssh は既定でそれを断る。
# 鍵の種類と host key の種類の両方を明示的に許す。新しい sshd には無害。
# もっと古い版で要る指定 (group1 の kex、cbc、hmac-md5、DSA) は版ごとに
# 違うので .qemu の SSHOPTS から読む。
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
 -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR \
 $SSHOPTS \
 -o PubkeyAcceptedAlgorithms=+ssh-rsa -o HostkeyAlgorithms=+ssh-rsa \
 $KEYARGS -p $SSHPORT root@127.0.0.1"
printf '%s\n' "$SSH" > "$DIR/$NAME.ssh"

echo "--- ssh が上がるのを待つ ---"
n=0
while [ $n -lt 120 ]; do
	if $SSH true 2>/dev/null; then
		echo "OK: $SSH"
		exit 0
	fi
	n=$((n + 1))
	sleep 5
done

echo "!! 10 分待っても ssh が上がらない。コンソールの末尾:"
tail -40 "$DIR/$NAME.console.log" 2>/dev/null || echo "  (コンソールに何も出ていない)"
echo "--- 鍵を取りに来たか (来ていなければネットワークが上がっていない) ---"
tail -5 "$DIR/$NAME.seed.log" 2>/dev/null
exit 1
