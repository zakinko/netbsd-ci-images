#!/bin/sh
# Runs inside NetBSD as root after chroot.sh: atf.sh <label>
# Runs the ffs-related ATF tests in the chroot at /t.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
L=$1
T=/t
TESTS="fs/ffs sbin/fsck_ffs sbin/newfs sbin/resize_ffs"
echo "=== atf $L: $(uname -v)"
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
