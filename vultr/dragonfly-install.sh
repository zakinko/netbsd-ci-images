#!/bin/sh
# DragonFly の live img の中で、指したディスクへ Vultr 向けの DragonFly を
# 入れる。ゲストの中で root で走らせる。
#
#   DISK=vbd0 PUBKEY=/root/authorized_keys sh dragonfly-install.sh
#
# installer(8) は通さない。あれは DFUI 越しの対話で、応答ファイルを置く道が
# 無い。handbook が書いている手順そのままを並べたほうが、何をしたかが残る。
#
# mkimg.sh の PROFILE=vultr と出口を揃えてある。生の raw を一つ吐き、それを
# release に置いて Vultr の snapshot-from-URL に食わせる。向こうの都合は
# NetBSD のときと同じで三つ。
#
#   - raw しか受け取らない。gz も qcow2 も通らない
#   - 置き場を GitHub の release にすると asset 一つ 2GiB の上限に当たる
#   - シリアルが出ていない。見えるのは web console が覗く VGA だけなので、
#     コンソールは既定のまま (comconsole にしない)
#
# 小さく焼いて、起きてから rc.d/growdisk がディスク一杯まで広げる。
set -e

DISK=${DISK:-vbd0}
LABEL=${LABEL:-DFLYVULTR}
IMGHOST=${IMGHOST:-dragonfly-vultr}
PUBKEY=${PUBKEY:-/root/authorized_keys}
GROWDISK=${GROWDISK:-/root/growdisk}
MNT=${MNT:-/mnt}
D=/dev/$DISK

[ -c "$D" ] || { echo "$0: $D が無い" >&2; exit 1; }
[ -s "$PUBKEY" ] || { echo "$0: 公開鍵が無い ($PUBKEY)" >&2; exit 1; }
[ -s "$GROWDISK" ] || { echo "$0: $GROWDISK が無い" >&2; exit 1; }

echo "=== $D に入れる (label=$LABEL)"
diskinfo "$D"

# 前の label が残っていると fdisk が拾う。
dd if=/dev/zero of="$D" bs=32k count=64 > /dev/null 2>&1

# slice 1 をディスク全体に取り、MBR に一次ブートを書く。ディスクはイメージ
# そのものの大きさなので、slice もそこまでしか伸びない。残りは配られた先で
# growdisk が取る。
fdisk -IB "$D"

# label を書く。a: を * にすると slice の残り全部。
#
# label: に名前を入れると /dev/part-by-label/<名前>.a として見えるように
# なり、fstab と loader.conf からディスクの名前を書かずに指せる。Vultr は
# virtio-blk なので vbd0、QEMU に IDE で繋げば ad0 になるが、同じイメージが
# どちらでも起動する。growdisk が自分のディスクを探すのにも使う。
disklabel64 -r -w "${D}s1" auto
disklabel64 "${D}s1" |
	awk -v l="$LABEL" '
		/^label:/		{ print "label: " l; next }
		/^16 partitions:/	{ print; print "  a:\t*\t*\t4.2BSD"; next }
					{ print }' |
	disklabel64 -R "${D}s1" /dev/stdin
disklabel64 -B "${D}s1"
disklabel64 "${D}s1"

newfs "${D}s1a"
mount "${D}s1a" "$MNT"

# live の / をそのまま写す。cpdup は各ディレクトリの .cpignore を見るので、
# 別の fs が乗っている所はそこで外す。-j0 は CHR/BLK を作らせない。
cat > /.cpignore <<'IGN'
/mnt
/dev
/proc
/tmp
/var/tmp
/var/run
/usr/obj
/.cpignore
IGN
cpdup -i0 -j0 / "$MNT"
rm -f /.cpignore "$MNT/.cpignore"
mkdir -p "$MNT/tmp" "$MNT/var/tmp" "$MNT/var/run" "$MNT/usr/obj" \
	"$MNT/proc" "$MNT/dev" "$MNT/mnt"
chmod 1777 "$MNT/tmp" "$MNT/var/tmp"

echo "=== 仕込み"
cat > "$MNT/etc/fstab" <<FSTAB
# ディスクの名前ではなく label で指す。virtio-blk なら vbd0、IDE なら ad0 と
# 名前が変わるが、どちらでも同じイメージが起動する。
/dev/part-by-label/$LABEL.a	/		ufs	rw,noatime	0 1
dummy				/tmp		tmpfs	rw		0 0
dummy				/var/tmp	tmpfs	rw		0 0
dummy				/var/run	tmpfs	rw,-C		0 0
proc				/proc		procfs	rw		0 0
FSTAB

# コンソールは既定 (VGA) のまま。Vultr にシリアルは出ていないので、
# comconsole にすると起動しなかったときに何も残らない。
cat > "$MNT/boot/loader.conf" <<LOADER
vfs.root.mountfrom="ufs:part-by-label/$LABEL.a"
LOADER

cat > "$MNT/etc/rc.conf" <<RCCONF
hostname="$IMGHOST"

# Vultr の NIC は virtio-net で vtnet0。QEMU の既定 (e1000) で起こしたときは
# em0 になるので両方書く。居ない口は netif が飛ばす。
ifconfig_vtnet0="DHCP"
ifconfig_em0="DHCP"

# 一番安い plan には IPv4 が付かない。住所は RA で降ってくるので dhclient
# だけでは足りない。DragonFly の SLAAC は MAC から EUI-64 で作るので、
# Vultr が台帳に載せる住所と食い違わない (NetBSD で dhcpcd を slaac hwaddr
# に書き換えたのと同じ話が、こちらでは要らない)。
ipv6_enable="YES"
rtsold_enable="YES"

sshd_enable="YES"
dumpdev="NO"

# 初回だけ、ディスク一杯まで広げて落ちる。
growdisk="YES"
growdisk_label="$LABEL"
RCCONF

# live の仕込みは持ち込まない。VPS にはホストから鍵を取りに行く先が無いので、
# 鍵は焼いてある。
rm -f "$MNT/etc/rc.local"

mkdir -p "$MNT/root/.ssh"
chmod 700 "$MNT/root/.ssh"
cat "$PUBKEY" > "$MNT/root/.ssh/authorized_keys"
chmod 600 "$MNT/root/.ssh/authorized_keys"

grep -q '^PermitRootLogin prohibit-password' "$MNT/etc/ssh/sshd_config" ||
	echo 'PermitRootLogin prohibit-password' >> "$MNT/etc/ssh/sshd_config"

# host key は焼かない。焼くと配った先が全部同じ鍵になる。初回に作らせる。
rm -f "$MNT/etc/ssh/ssh_host_"*
cat > "$MNT/etc/rc.d/sshkeygen" <<'KEYGEN'
#!/bin/sh
#
# PROVIDE: sshkeygen
# REQUIRE: mountcritremote
# BEFORE: sshd
#
# host key はイメージに焼いていない。初回の起動で作る。
. /etc/rc.subr
name="sshkeygen"
start_cmd="ssh-keygen -A"
stop_cmd=":"
load_rc_config $name
run_rc_command "$1"
KEYGEN
chmod 555 "$MNT/etc/rc.d/sshkeygen"

install -m 555 -o root -g wheel "$GROWDISK" "$MNT/etc/rc.d/growdisk"

sync
umount "$MNT"
fsck -p "${D}s1a" || true
echo "=== 入った"
