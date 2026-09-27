#!/bin/sh
# Runs inside NetBSD as root: atf.sh <label>
# Unpacks /root/trunk/<label>/{base,etc,tests}.tar.xz into a tmpfs
# chroot at /t and runs the ffs-related ATF tests there.  The chroot is
# left mounted for ck.sh.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
L=$1
S=/root/trunk/$L
T=/t
TESTS="fs/ffs sbin/fsck_ffs sbin/newfs sbin/resize_ffs"
mkdir -p $T
if [ ! -x $T/bin/sh ]; then
	mount -t tmpfs -o -s6g tmpfs $T || exit 1
	for s in base etc tests; do
		xz -dc $S/$s.tar.xz | tar -xpf - -C $T || exit 1
	done
	mount -t null /dev $T/dev || exit 1
fi
echo "=== atf $L: $(uname -v)"
echo "sets: $(cat $S/rev)"
mkdir -p /root/atf-$L
for d in $TESTS; do
	n=$(echo $d | tr / _)
	chroot $T /bin/sh -c "cd /usr/tests/$d && atf-run" \
	    > /root/atf-$L/$n.raw 2>/root/atf-$L/$n.err
	echo "--- $d (atf-run rc=$?)"
	chroot $T atf-report -o ticker:- -o csv:/tmp/$n.csv \
	    < /root/atf-$L/$n.raw | sed -n '/^Summary/,$p'
	cp $T/tmp/$n.csv /root/atf-$L/
done
