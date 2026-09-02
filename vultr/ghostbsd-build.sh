#!/bin/sh
# Vultr へ持っていく GhostBSD の生イメージを組む。GhostBSD が走っている
# 機械の上で、繋いだ空のディスクへ入れる。
#
#   DISK=vtbd1 sh ghostbsd-build.sh
#
# 配られている ISO は desktop 込みで、入れると 4 GiB を超える。中身は
# llvm19 が 1.77GiB (mesa の依存)、gcc14 が 359MiB、firefox が 334MiB…
# という内訳で、置き場の上限 (release の asset 一つ 2GiB) に入らない。
# pkg で削ろうとしても solver が「解けない」と言って外させない。
#
# そこで削るのではなく、**最初から server として組む**。GhostBSD 自身の
# ISO 構築ツール (ghostbsd-build) が使っている packages/base の一覧を、
# 空の pool へ入れるだけ。圧縮も向こうに倣って zstd-9。出来上がりは 512MB。
#
# 拡張は FreeBSD 標準の rc.d/growfs に任せる。ZFS も見てくれるので、
# gpart resize と zpool online -e が初回の起動で走る。ただし
# KEYWORD: firstboot なので /firstboot の目印が要る。
set -e
export ASSUME_ALWAYS_YES=yes

DISK=${DISK:-vtbd1}
POOL=${POOL:-gbsd}
IMGHOST=${IMGHOST:-ghostbsd-vultr}
PKGLIST=${PKGLIST:-/root/gbase.txt}
PUBKEY=${PUBKEY:-/root/vultr_key.pub}
M=${M:-/mnt}

[ -s "$PKGLIST" ] || { echo "$0: package の一覧が無い ($PKGLIST)" >&2; exit 1; }
[ -s "$PUBKEY" ] || { echo "$0: 公開鍵が無い ($PUBKEY)" >&2; exit 1; }

zpool destroy -f $POOL 2>/dev/null || true
gpart destroy -F $DISK 2>/dev/null || true

# BIOS 起動。Vultr の snapshot は uefi:false で取り込む。
gpart create -s gpt $DISK
gpart add -t freebsd-boot -s 512k -i 1 $DISK
gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i 1 $DISK
gpart add -t freebsd-zfs -i 2 $DISK
gpart show $DISK

zpool create -f -o altroot=$M -O compression=zstd-9 -O atime=off -m none \
	$POOL ${DISK}p2
zfs create -o mountpoint=/ $POOL/ROOT
zpool set bootfs=$POOL/ROOT $POOL

# base の一覧に pkg は入っていない。VPS では要るので足す。
echo "=== base を入れる"
pkg -r $M install -y pkg $(grep -vE '^[[:space:]]*$|^#' "$PKGLIST" | tr '\n' ' ')

cat > $M/boot/loader.conf <<LOADER
zfs_load="YES"
vfs.root.mountfrom="zfs:$POOL/ROOT"
LOADER

cat > $M/etc/rc.conf <<RCCONF
hostname="$IMGHOST"
zfs_enable="YES"
growfs_enable="YES"

# Vultr の NIC は virtio-net で vtnet0。一番安い plan には IPv4 が付かず、
# 住所は RA で降ってくる。FreeBSD の SLAAC は MAC から EUI-64 で作るので、
# Vultr が台帳に載せる住所と食い違わない。
ifconfig_vtnet0="DHCP"
ifconfig_vtnet0_ipv6="inet6 accept_rtadv"
rtsold_enable="YES"

sshd_enable="YES"
RCCONF

: > $M/etc/fstab

# rc.d/growfs は KEYWORD: firstboot なので、この目印が無いと走らない。
# 走り終えると rc が自分で消す。
: > $M/firstboot

mkdir -p $M/root/.ssh
chmod 700 $M/root/.ssh
cp "$PUBKEY" $M/root/.ssh/authorized_keys
chmod 600 $M/root/.ssh/authorized_keys
grep -q '^PermitRootLogin prohibit-password' $M/etc/ssh/sshd_config 2>/dev/null ||
	echo 'PermitRootLogin prohibit-password' >> $M/etc/ssh/sshd_config
# host key は焼かない。焼くと配った先が全部同じ鍵になる。sshd が初回に作る。
rm -f $M/etc/ssh/ssh_host_*

zfs list -o name,used,avail,compressratio $POOL
zpool export $POOL
echo "=== 組めた"
