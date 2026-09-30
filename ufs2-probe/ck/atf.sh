#!/bin/sh
# Runs inside the guest as root: atf.sh <label>
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
L=$1
O=/root/p/atf-$L
mkdir -p $O
for d in fs/ffs sbin/fsck_ffs; do
	n=$(echo $d | tr / _)
	(cd /usr/tests/$d && atf-run > $O/$n.raw 2>&1)
	atf-report -o ticker:$O/$n.txt < $O/$n.raw
	echo "== $L $d"
	awk '/^(Failed test cases:|Summary for)/{f=1} f' $O/$n.txt
done
