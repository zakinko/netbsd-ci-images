#!/bin/sh
# Runs inside the guest as root: atf.sh <label>
# atf-run where it exists, kyua otherwise.
PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/pkg/bin; export PATH
L=$1
O=/root/p/atf-$L
mkdir -p $O
echo "== $L runners: atf-run=$(command -v atf-run) kyua=$(command -v kyua)"
for d in fs/ffs sbin/fsck_ffs; do
	n=$(echo $d | tr / _)
	echo "== $L $d"
	if command -v atf-run >/dev/null 2>&1; then
		(cd /usr/tests/$d && atf-run > $O/$n.raw 2>&1)
		atf-report -o ticker:$O/$n.txt < $O/$n.raw
		awk '/^(Failed test cases:|Summary for)/{f=1} f' $O/$n.txt
	elif command -v kyua >/dev/null 2>&1; then
		(cd /usr/tests && kyua test --results-file=$O/$n.db $d > $O/$n.txt 2>&1)
		tail -6 $O/$n.txt
		kyua report --results-file=$O/$n.db --results-filter=failed,broken 2>&1 | grep -vE '^$' | head -40
	else
		echo "no ATF runner"; ls /usr/bin/atf* 2>&1 | head
	fi
done
