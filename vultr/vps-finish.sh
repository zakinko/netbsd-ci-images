#!/bin/sh
# 組んだ Vultr 用イメージを、配れる形に仕上げる。ゲスト (NetBSD) の中で走る。
#
#   - 焼いた鍵と host key を外す。配る版に鍵を焼くと、落とした人が立てた VPS に
#     焼いた側の鍵で root で入れることになる
#   - 代わりに metadata から取る rc.d を入れる
#   - 当て物を当てたカーネルが渡されていれば差し替える。9.x では配布された
#     ままのカーネルが Vultr のディスクを掴めない
#
# 渡すもの:
#   /root/vultrkey        rc.d へ入れる本体
#   /root/netbsd-virtio1  差し替えるカーネル (要るときだけ)
set -e
PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PATH

IMG=$(ls /root/*-vultr.img)
M=${M:-/mnt/vpsimg}
VND=${VND:-vnd3}

umount $M 2>/dev/null || true
vnconfig -u $VND 2>/dev/null || true
mkdir -p $M
vnconfig -c $VND "$IMG"
mount /dev/${VND}a $M

rm -f $M/root/.ssh/authorized_keys
# host key を焼くと配った先が全部同じ鍵になる。sshd が初回に作る。
rm -f $M/etc/ssh/ssh_host_*

install -m 555 -o root -g wheel /root/vultrkey $M/etc/rc.d/vultrkey
grep -q '^vultrkey=' $M/etc/rc.conf || echo 'vultrkey=YES' >> $M/etc/rc.conf

if [ -s /root/netbsd-virtio1 ]; then
	cp -p $M/netbsd $M/netbsd.stock
	cp /root/netbsd-virtio1 $M/netbsd
	chmod 755 $M/netbsd
	echo "=== カーネルを当て物入りに差し替えた"
fi

ls -l $M/netbsd $M/etc/rc.d/vultrkey
ls -la $M/root/.ssh/ 2>&1 | tail -2
df -h $M | tail -1
sync
umount $M
vnconfig -u $VND
echo "=== 仕上げた"
