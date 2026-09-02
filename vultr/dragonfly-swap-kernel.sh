#!/bin/sh
# 焼いた DragonFly のイメージを、当て物入りのカーネルに差し替えて配れる形に
# する。ゲストの中で走る。二本目のディスク (vbd1) に焼いたイメージを繋いで
# おくこと。
#
# 渡すもの: /root/vultrkey (metadata から公開鍵を取る rc.d)
set -e
PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PATH

K=/usr/obj/usr/src/sys/X86_64_GENERIC/kernel.stripped
M=/mnt/img
[ -s "$K" ] || { echo "当て物入りのカーネルが無い" >&2; exit 1; }

mkdir -p $M
umount $M 2>/dev/null || true
mount /dev/vbd1s1a $M

# 動いているカーネルには schg が立っている。焼いた側にも立っていることがある。
chflags noschg $M/boot/kernel/kernel 2>/dev/null || true
cp -p $M/boot/kernel/kernel $M/boot/kernel/kernel.stock
cp "$K" $M/boot/kernel/kernel
chmod 755 $M/boot/kernel/kernel

# 配る版に鍵は焼かない。起動時に metadata から取る。
rm -f $M/root/.ssh/authorized_keys
rm -f $M/etc/ssh/ssh_host_*
install -m 555 -o root -g wheel /root/vultrkey $M/etc/rc.d/vultrkey
grep -q '^vultrkey=' $M/etc/rc.conf || echo 'vultrkey=YES' >> $M/etc/rc.conf

ls -l $M/boot/kernel/kernel $M/etc/rc.d/vultrkey
df -h $M | tail -1
sync
umount $M
echo "=== 仕上げた"
