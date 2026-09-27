#!/bin/sh
# Runs inside NetBSD as root: chroot.sh <label>
# Unpacks /root/trunk/<label>/{base,etc,tests}.tar.xz into a tmpfs at
# /t, with /dev null-mounted and the tests set also as /t/tmp/tests.tar
# for bench.sh.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
S=/root/trunk/$1
T=/t
mkdir -p $T
if [ -x $T/bin/sh ]; then
	umount $T/dev; umount $T || exit 1
fi
mount -t tmpfs -o -s7g tmpfs $T || exit 1
for s in base etc tests; do
	xz -dc $S/$s.tar.xz | tar -xpf - -C $T || exit 1
done
xz -dc $S/tests.tar.xz > $T/tmp/tests.tar
mount -t null /dev $T/dev || exit 1
echo "chroot /t: $1 ($(cat $S/rev))"
