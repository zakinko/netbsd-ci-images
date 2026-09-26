#!/bin/sh
# Runs inside NetBSD as root: atf.sh <label>
# Unpacks the trunk base/etc/tests sets into a tmpfs chroot and runs
# tests/fs/ffs and tests/sbin/fsck_ffs.  With label "patched" the
# patched librumpfs_ffs and fsck_ffs replace the stock ones first.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
L=$1
S=/root/trunk
T=/t
mkdir -p $T
if [ ! -x $T/bin/sh ]; then
	mount -t tmpfs -o -s5g tmpfs $T || exit 1
	for s in base etc tests; do
		xz -dc $S/$s.tar.xz | tar -xpf - -C $T || exit 1
	done
	mount -t null /dev $T/dev || exit 1
fi
lib=$(cd $S && ls librumpfs_ffs.so.*.*)
if [ "$L" = patched ]; then
	cp $S/$lib $T/usr/lib/$lib && cp $S/fsck_ffs $T/sbin/fsck_ffs || exit 1
fi
echo "=== atf $L: $(uname -v)"
(cd $T && sha256 usr/lib/$lib sbin/fsck_ffs)
mkdir -p /root/atf-$L
for d in fs/ffs sbin/fsck_ffs; do
	n=$(echo $d | tr / _)
	chroot $T /bin/sh -c "cd /usr/tests/$d && atf-run" \
	    > /root/atf-$L/$n.raw 2>/root/atf-$L/$n.err
	echo "--- $d (atf-run rc=$?)"
	chroot $T atf-report -o ticker:- -o csv:/tmp/$n.csv \
	    < /root/atf-$L/$n.raw | sed -n '/^Summary/,$p'
	cp $T/tmp/$n.csv /root/atf-$L/
done
