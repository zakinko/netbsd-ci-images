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

# t7.sh <label> fail: the same remount, made to fail after the kernel has
# taken the file system for writing (a log flag with a journal of an
# unknown type; the remount gives EFTYPE).  What does the unmount write?
[ "$2" = fail ] || exit 0
echo "=== $1: a remount to rw that fails late"
i=t7/$1-f.img; xz -dc plain.img.xz > $i
./poke $i wapbl; ./poke $i flags
echo "check-hash lines of fsck_ffs before: $(fsck_ffs -f -n $i 2>&1 | grep -c 'CHECK HASH')"
vndconfig vnd1 $i || exit 1
mount -t ffs -o ro,force /dev/vnd1a /mnt/p; echo "mount ro,force rc=$?"
mount -u -o rw /mnt/p; echo "remount rw rc=$?"; mount | grep /mnt/p
dmesg | tail -4
umount /mnt/p; echo "umount rc=$?"; vndconfig -u vnd1
./poke $i flags
echo "check-hash lines of fsck_ffs after: $(fsck_ffs -f -n $i 2>&1 | grep -c 'CHECK HASH')"
fsck_ffs -f -n $i 2>&1 | grep -vE '^\*\* Phase|^$|DIOCGDINFO|character device|^CONTINUE' | head -8
