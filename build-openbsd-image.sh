#!/bin/sh
# OpenBSD を autoinstall で QEMU に入れ、qcow2 に固める。
#
#   sh build-openbsd-image.sh <arch> <release>
#   例: sh build-openbsd-image.sh i386 7.9
#
# NetBSD 側は anita が sysinst をコンソール越しに操る。OpenBSD には
# autoinstall(8) が最初からあるので、応答ファイルを HTTP に置いておけば
# 質問には全部それが答える。anita に相当するものは要らない。
#
# こちらから叩くのは一箇所だけ。ブートローダの boot> は画面側にしか出ない
# ので、QEMU のモニタから sendkey で "set tty com0" と打ち込む。そこから
# 先はシリアルに出るので、あとは黙って見ているだけでよい。
#
# 鍵は焼かない。NetBSD 側と同じで、起動のたびにゲストが
# http://10.0.2.2:8123/authorized_keys を取りに行く。その仕込みは
# site<REL>.tgz の install.site でやる。焼かない理由は README のとおりで、
# 公開したイメージからどの鍵が root を通せるか分からないようにするため。
#
# 出来上がりは openbsd-<arch>-<release>.qcow2 と、繋ぎ方を書いた .qemu。

set -eu

ARCH=$1
REL=$2
RELNO=$(echo "$REL" | tr -d .)

BASE=${BASE:-$(cd "$(dirname "$0")" && pwd)}
WORK=${WORK:-${TMPDIR:-/tmp}/obimg-$ARCH-$REL}
MIRROR=${MIRROR:-https://cdn.openbsd.org/pub/OpenBSD}
DISK=${DISK:-24G}
MEM=${MEM:-1024}
INST_PORT=${INST_PORT:-8124}
SEED_PORT=${SEED_PORT:-8123}
WAIT=${WAIT:-3600}
OUT=$BASE/openbsd-$ARCH-$REL

case $ARCH in
i386)	QEMU=qemu-system-i386 ;;
amd64)	QEMU=qemu-system-x86_64 ;;
*)	QEMU=qemu-system-$ARCH ;;
esac

ACCEL=tcg
case $ARCH in
i386|amd64) [ -w /dev/kvm ] && ACCEL=kvm ;;
esac

echo "=== OpenBSD $REL / $ARCH ==="
echo "    $MIRROR/$REL/$ARCH"
echo "    accel=$ACCEL disk=$DISK mem=${MEM}M"
[ "$ACCEL" = tcg ] && echo "    !! 加速なし。相当遅い。"

rm -rf "$WORK"
mkdir -p "$WORK/serve"
SOCK=$(mktemp -d /tmp/obimg.XXXXXX)

cleanup() {
	rc=$?
	[ -z "${HTTPD:-}" ] || kill "$HTTPD" 2>/dev/null || true
	if [ -s "$SOCK/qemu.pid" ] && kill -0 "$(cat "$SOCK/qemu.pid")" 2>/dev/null; then
		kill "$(cat "$SOCK/qemu.pid")" 2>/dev/null || true
	fi
	rm -rf "$SOCK"
	exit $rc
}
trap cleanup EXIT INT TERM

echo "=== install メディアを取る ==="
ISO=$WORK/install$RELNO.iso
curl -fsSL -o "$ISO" "$MIRROR/$REL/$ARCH/install$RELNO.iso"
ls -lh "$ISO"

# ------------------------------------------------------------------
echo "=== 応答ファイルと site set を作る ==="

# install.site は導入の最後に一度だけ走る。ここで鍵を取りに行く仕掛けを
# 置く。NetBSD 側の /etc/rc.d/seed_key と同じ役割。
mkdir -p "$WORK/site/etc/rc.d"
cat > "$WORK/site/etc/rc.d/seed_key" <<SEED
#!/bin/ksh
#
# 起動のたびに host から authorized_keys を取りに行く。イメージに鍵を
# 焼かないための仕掛けで、配る側は runvm.sh。
daemon="/bin/true"
. /etc/rc.d/rc.subr
rc_pre() {
	mkdir -p /root/.ssh
	chmod 700 /root/.ssh
	ftp -o /root/.ssh/authorized_keys \\
	    http://10.0.2.2:$SEED_PORT/authorized_keys || true
	chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
}
rc_cmd \$1
SEED
chmod 755 "$WORK/site/etc/rc.d/seed_key"

cat > "$WORK/site/install.site" <<'SITE'
#!/bin/sh
# 導入の最後に一度だけ走る。
rcctl enable seed_key
rcctl set seed_key flags ""
echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config
rcctl enable sshd
# CI から使うだけなので、起動を待たせるものを減らす。
rcctl disable smtpd || true
SITE
chmod 755 "$WORK/site/install.site"

(cd "$WORK/site" && tar czf "$WORK/serve/site$RELNO.tgz" install.site etc)

# autoinstall(8) は質問文の頭で照合し、書いていない質問は既定を使う。
# だから要るものだけ書く。同じ質問が二度出るものは、出る順に二行書く。
cat > "$WORK/serve/install.conf" <<CONF
System hostname = ci
Password for root account = *************
Allow root ssh login = prohibit-password
Setup a user = no
Start sshd(8) by default = yes
Do you expect to run the X Window System = yes
What timezone are you in = UTC
Which disk is the root disk = sd0
Encrypt the root disk = no
Use (W)hole disk MBR, whole disk (G)PT or (E)dit = whole
Use (A)uto layout, (E)dit auto layout, or create (C)ustom layout = auto
Location of sets = cd0
Set name(s) = done
Directory does not contain SHA256.sig. Continue without verification = yes
Location of sets = http
HTTP Server = 10.0.2.2:$INST_PORT
Server directory =
Set name(s) = site$RELNO.tgz
Location of sets = done
CONF
cat "$WORK/serve/install.conf"

python3 -m http.server "$INST_PORT" --bind 0.0.0.0 \
	--directory "$WORK/serve" > "$WORK/httpd.log" 2>&1 &
HTTPD=$!

# ------------------------------------------------------------------
echo "=== 起動 ==="
qemu-img create -f qcow2 "$WORK/disk.qcow2" "$DISK" > /dev/null

$QEMU -machine accel=$ACCEL -cpu max -m "$MEM" -smp 2 \
	-drive file="$WORK/disk.qcow2",if=virtio,format=qcow2 \
	-drive file="$ISO",media=cdrom,readonly=on \
	-boot d \
	-netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
	-chardev socket,id=con,path="$SOCK/con.sock",server=on,wait=off,logfile="$WORK/console.log" \
	-serial chardev:con \
	-monitor unix:"$SOCK/qmon.sock",server,nowait \
	-display none -daemonize -pidfile "$SOCK/qemu.pid"

# socket へ流し込んで戻ってくるための道具。nc は使わない。Ubuntu の
# netcat-openbsd は stdin が尽きても書き込み側を閉じず (閉じるのは -N を
# 付けたときだけ)、QEMU は client の EOF を見るまで繋ぎを切らないので、
# 双方が相手を待って nc が戻らず、そこで script 全体が止まる。macOS の nc は
# stdin の EOF で書き込み側を閉じるので手元では通り、CI に持って行って初めて
# 「イメージを作る」が job の上限 (120 分) まで黙って固まった。python3 は
# 応答ファイルを配るのに既に要るので、同じもので送って、送り終えたら
# 書き込み側を閉じ、相手が切るのを 2 秒だけ待つ。script は -c で渡す。
# heredoc で渡すと stdin がそれに置き換わり、送る中身が読めない。
tosock() {
	python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall(sys.stdin.buffer.read())
s.shutdown(socket.SHUT_WR)
s.settimeout(2)
try:
    while s.recv(4096):
        pass
except OSError:
    pass
' "$1"
}

# 一行だけ打ち込むための道具。boot> に届かせるのが目的なので、要る文字
# しか用意していない。
sendline() {
	_s=$1
	{
		while [ -n "$_s" ]; do
			_c=$(printf '%s' "$_s" | cut -c1)
			_s=$(printf '%s' "$_s" | cut -c2-)
			case $_c in
			[a-z0-9])	echo "sendkey $_c" ;;
			' ')	echo "sendkey spc" ;;
			-)	echo "sendkey minus" ;;
			*)	echo "sendline に無い文字: $_c" >&2; return 1 ;;
			esac
		done
		echo "sendkey ret"
	} | tosock "$SOCK/qmon.sock" > /dev/null 2>&1
}

# boot> は 5 秒で流れる。何秒後に出るかは箱の速さ次第で、加速の無い TCG では
# 一分以上かかることもある。固定で待つと外す -- 外しても画面側で普通に
# 進んでしまうので、console.log が空のまま何も起きない形になる。実際
# macOS/arm64 の TCG で sleep 8 では届かず、90 分待って何も出なかった。
#
# 当たるまで打ち直す。3 秒ごとなら 5 秒の窓はまず拾える。シリアルに一文字
# でも出た時点で当たったと分かるので、そこで止める。BIOS がまだ動いている
# 間の打鍵はどこにも行かないので害は無い。
echo "=== コンソールをシリアルへ回す ==="
i=0
while [ $i -lt "${BOOTWAIT:-180}" ]; do
	sendline 'set tty com0' 2>/dev/null
	sendline boot 2>/dev/null
	sleep 3
	i=$((i + 3))
	[ -s "$WORK/console.log" ] && break
done
if [ -s "$WORK/console.log" ]; then
	echo "    $i 秒でシリアルに出た"
else
	echo "    !! ${BOOTWAIT:-180} 秒打ち続けてもシリアルに出ない"
fi

# ------------------------------------------------------------------
echo "=== autoinstall を待つ ==="
# 応答ファイルの場所は、最初の質問に一度だけ答えれば済む。
i=0
answered=no
while [ $i -lt "$WAIT" ]; do
	kill -0 "$(cat "$SOCK/qemu.pid")" 2>/dev/null || break
	if [ "$answered" = no ] && grep -q '(A)utoinstall' "$WORK/console.log" 2>/dev/null; then
		printf 'a\n' | tosock "$SOCK/con.sock" > /dev/null 2>&1 || true
		sleep 3
		printf 'http://10.0.2.2:%s/install.conf\n' "$INST_PORT" \
			| tosock "$SOCK/con.sock" > /dev/null 2>&1 || true
		answered=yes
		echo "--- 応答ファイルの場所を渡した ---"
	fi
	grep -q 'CONGRATULATIONS' "$WORK/console.log" 2>/dev/null && break
	sleep 10
	i=$((i + 10))
done

tail -40 "$WORK/console.log" | tr -d '\r'

grep -q 'CONGRATULATIONS' "$WORK/console.log" 2>/dev/null || {
	echo "=== 導入が終わっていない ($i 秒待った) ==="
	exit 1
}

echo "=== 止める ==="
printf 'halt -p\n' | tosock "$SOCK/con.sock" > /dev/null 2>&1 || true
sleep 20
kill "$(cat "$SOCK/qemu.pid")" 2>/dev/null || true
sleep 2

echo "=== qcow2 に固める ==="
rm -f "$OUT.qcow2"
qemu-img convert -O qcow2 -c "$WORK/disk.qcow2" "$OUT.qcow2"
qemu-img info "$OUT.qcow2" | head -5

cat > "$OUT.qemu" <<META
ARCH=$ARCH
RELEASE=$REL
OPSYS=OpenBSD
QEMU=$QEMU
FORMAT=qcow2
DISKARGS="-drive file=@IMG@,format=qcow2,if=virtio,cache=unsafe"
NICDEV=virtio-net-pci
ROOTDEV=sd0a
SEED_PORT=$SEED_PORT
META
echo "--- 繋ぎ方 ---"
cat "$OUT.qemu"
echo "OK: $OUT.qcow2"
