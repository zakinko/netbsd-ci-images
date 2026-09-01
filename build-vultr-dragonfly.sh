#!/bin/sh
# Vultr へ持っていく DragonFly の生イメージを組む。
#
#   sh build-vultr-dragonfly.sh [版]
#   例: sh build-vultr-dragonfly.sh 6.4.2
#
# NetBSD の側は mkimg.sh が配布セットを展開して組むが、DragonFly には
# 配布セットが無い。公開されているのは起動できる live の img で、入れる手も
# その中から走らせる installer(8) しかない。そこで live を QEMU で起こし、
# **その中で** vultr/dragonfly-install.sh を走らせて、繋いでおいた生ディスクへ
# 入れる。出来たものがそのまま Vultr へ渡す raw になる。
#
# 焼くのは 1 GiB。置き場 (release の asset 一つ 2GiB) に収めるためで、
# 配られた先で rc.d/growdisk がディスク一杯まで広げる。
#
# 環境変数:
#   SIZE      焼く大きさ (MiB)。既定 1024
#   PUBKEY    root に通す公開鍵。既定は ./authorized_keys、無ければ
#             ~/.ssh/id_rsa.pub
#   IMGHOST   焼くホスト名
set -eu

VER=${1:-6.4.2}
TARGET=dragonfly-$VER-x86_64
NAME=$TARGET-vultr
SIZE=${SIZE:-1024}
IMGHOST=${IMGHOST:-dragonfly-vultr}

BASE=${BASE:-$(cd "$(dirname "$0")" && pwd)}
OUTDIR=${OUTDIR:-$BASE/out}
WORK=${WORK:-${TMPDIR:-/tmp}/vultr-$TARGET}
LIVE=$OUTDIR/$TARGET.raw
IMG=$OUTDIR/$NAME.img
KEY=$OUTDIR/$TARGET.id

# 焼く鍵。VPS にはホストから取りに行く先が無いので、これだけは焼くしかない。
# 焼いた鍵は release に置いたイメージを見れば分かるので、Vultr が取り込み
# 終わったら asset は落とすこと。
if [ -z "${PUBKEY:-}" ]; then
	if [ -s "$BASE/authorized_keys" ]; then
		PUBKEY=$BASE/authorized_keys
	else
		PUBKEY=$HOME/.ssh/id_rsa.pub
	fi
fi
[ -s "$PUBKEY" ] || { echo "$0: 公開鍵が無い ($PUBKEY)" >&2; exit 1; }
echo "=== 焼く鍵: $PUBKEY"

# 入れる元。公式の live img から組んである。無ければ組む。
[ -s "$LIVE" ] || sh "$BASE/build.sh" "$TARGET"
[ -s "$KEY" ] || { echo "$0: $KEY が無い" >&2; exit 1; }

mkdir -p "$WORK" "$OUTDIR"
rm -f "$IMG"
qemu-img create -f raw "$IMG" "${SIZE}M" > /dev/null
echo "=== 入れる先を作った (${SIZE} MiB)"

# emulation のままだと十倍以上遅い。あれば KVM を使う。
ACCEL=
[ -w /dev/kvm ] && ACCEL="-enable-kvm"

free_port() {
	python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}
SSHPORT=${SSHPORT:-$(free_port)}

# live は VGA が在ると loader も画面側にしか出さないので -nographic で起こす。
# 打ち込みは FIFO から入れる。
# live の rc.local は起動のたびに 8123 へ鍵を取りに来る (build.sh が焼いた)。
# 配っておかないと 60 回失敗するまで 2 分待たされ、その間 sshd も上がらない。
mkdir -p "$WORK/seed"
cp "$KEY.pub" "$WORK/seed/authorized_keys"
python3 "$BASE/mirror-alias.py" --port 8123 --dir "$WORK/seed" \
	> "$WORK/seed.log" 2>&1 &
SEEDPID=$!

FIFO=$WORK/in
CONLOG=$OUTDIR/$NAME.build.log
rm -f "$FIFO"; mkfifo "$FIFO"
(sleep 36000 > "$FIFO" &)
sleep 1
qemu-system-x86_64 $ACCEL -m 2048 -smp 2 \
	-drive file="$LIVE",format=raw \
	-drive file="$IMG",format=raw,if=virtio \
	-nic user,hostfwd=tcp:127.0.0.1:"$SSHPORT"-:22 \
	-nographic < "$FIFO" > "$CONLOG" 2>&1 &
EMUPID=$!
trap 'kill $EMUPID $SEEDPID 2>/dev/null || true' EXIT INT TERM
sleep 2

SSHCMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o BatchMode=yes -o ConnectTimeout=15 -o LogLevel=ERROR \
	-i $KEY -p $SSHPORT root@127.0.0.1"

# live は自分で網を上げて sshd まで来る。targets/*.conf が rc.conf に
# ifconfig_em0 を書き足しているためで、コンソールには何も打たない。
#
# 打たない理由は loader にある。**この loader は促しを出した直後の何文字かを
# 落とす** (boot が bot に、次は oot になって "unknown command" で止まった)。
# 打鍵を 0.08 秒から 0.2 秒に伸ばしても直らない。しかも促しに落とすと自動起動
# の待ち時間も止まるので、一文字落とした時点でその機械は永久に上がってこない。
# 通す回数は少ないほどよく、ここでは一度も通らずに済ませられる。
echo "=== live を起こす (ssh=$SSHPORT)"
n=0
while [ $n -lt 60 ]; do
	if $SSHCMD true 2>/dev/null; then break; fi
	n=$((n + 1)); sleep 5
done
[ $n -lt 60 ] || {
	echo "$0: live に ssh が通らない。" >&2
	echo "  古い $LIVE は rc.conf に ifconfig_em0 を持っていない。" >&2
	echo "  rm $LIVE して組み直すこと。" >&2
	exit 1
}
echo "=== live に入れた"

# root の shell は csh。込み入ったものは sh に食わせる。
$SSHCMD 'cat > /root/growdisk'   < "$BASE/vultr/dragonfly-growdisk"
$SSHCMD 'cat > /root/install.sh' < "$BASE/vultr/dragonfly-install.sh"
$SSHCMD "cat > /root/authorized_keys" < "$PUBKEY"
$SSHCMD "env DISK=vbd0 IMGHOST=$IMGHOST sh /root/install.sh"

echo "=== 落とす"
$SSHCMD 'shutdown -p now' 2>/dev/null || true
n=0
while [ $n -lt 60 ] && kill -0 $EMUPID 2>/dev/null; do n=$((n + 1)); sleep 2; done
kill $EMUPID 2>/dev/null || true

ls -l "$IMG"
[ "$(wc -c < "$IMG")" -lt 2147483648 ] ||
	{ echo "$0: 2GiB を超えた。SIZE を減らすこと" >&2; exit 1; }

# 起こし方を書き出す。Vultr は virtio-blk なので、確かめるときも同じ繋ぎ方に
# する。コンソールは焼いた側が VGA のままなので、シリアルで見たいときは
# loader の促しで set console="comconsole" と打つ。
cat > "$OUTDIR/$NAME.qemu" <<META
OS=dragonfly
VERSION=$VER
PORT=x86_64
LICENSE=free
VMM=qemu
QEMU=qemu-system-x86_64
FORMAT=raw
CONSOLE=stdio
QEMUARGS="-m 1024 -smp 2 -drive file=@IMG@,format=raw,if=virtio"
CHECK=ssh
SSH=yes
NOTE="Vultr へ渡す raw。root の鍵は焼いてある。初回の起動で growdisk が広げて一度落ちる"
META
echo "OK: $IMG"
