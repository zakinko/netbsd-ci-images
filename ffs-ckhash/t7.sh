#!/bin/sh
# ゲストの中で root として走る: t7.sh <label>
# check hash 付きの FreeBSD UFS2 を ro で mount し、rw へ remount する。
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
P=/root/p/ck; cd $P || exit 1
cc -o poke poke.c || exit 1
mkdir -p t7 /mnt/p
echo "=== $1: $(uname -v)"
i=t7/$1.img; xz -dc plain.img.xz > $i; cksum -a sha256 $i
./poke $i flags
vndconfig vnd1 $i || exit 1
mount -t ffs -o ro /dev/vnd1a /mnt/p; echo "mount ro rc=$?"
mount -u -o rw /mnt/p; echo "remount rw rc=$?"; mount | grep /mnt/p
dmesg | tail -2
echo x > /mnt/p/new; echo "write rc=$?"
umount /mnt/p; echo "umount rc=$?"; vndconfig -u vnd1
cksum -a sha256 $i
./poke $i flags
fsck_ffs -f -n $i 2>&1 | grep -vE '^\*\* Phase|^$|DIOCGDINFO|character device|^CONTINUE'
