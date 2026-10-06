#!/bin/sh
# Runs on the Ubuntu runner with amd64-11.0 up.
#   stock trunk kernel, stock sets:    ATF, bench
#   each $STEPS kernel, patched sets:  bench
#   patched kernel, patched sets:      ATF, ck.sh, bench
set -x
SSH=$(cat ./amd64-11.0.ssh)
boot() {	# kernel.xz
	xz -dc $1 | $SSH 'cat > /netbsd.new'
	$SSH '[ -f /netbsd.11 ] || cp /netbsd /netbsd.11; mv /netbsd.new /netbsd && sync && (sleep 2; /sbin/shutdown -r now) >/dev/null 2>&1 &'
	sleep 20
	n=0; until $SSH true 2>/dev/null; do
		n=$((n+1))
		if [ $n -gt 60 ]; then
			echo "=== $1 did not come back; console:"
			tail -80 amd64-11.0.console.log
			echo "=== panics and tracebacks on the console:"
			grep -a -B5 -A45 'Begin traceback\|panic:' amd64-11.0.console.log |
			    tail -300
			return 1
		fi
		sleep 5
	done
	$SSH uname -v
	crashinfo "$1"
}
# After a panic, savecore leaves a dump; print its message buffer and
# the stack of the thread that panicked, then remove it.
crashinfo() {	# label
	$SSH 'for c in /var/crash/netbsd.*.core.gz; do
		[ -f "$c" ] || exit 0
		k=${c%.core.gz}.gz
		echo "=== crash dump $c"
		gunzip -c $c > /tmp/core && gunzip -c $k > /tmp/kern &&
		    { dmesg -M /tmp/core -N /tmp/kern | tail -250
		      echo "--- bt"; echo bt | crash -M /tmp/core -N /tmp/kern 2>&1 | tail -60; }
		rm -f /tmp/core /tmp/kern $c $k
	done' 2>&1 | sed "s/^/[$1] /" | tee -a crash.txt
}
bench() {	# label
	$SSH "cp /root/bench.sh /t/tmp/ && /usr/sbin/chroot /t sh /tmp/bench.sh $1 /tmp/tests.tar" 2>&1 |
	    tee bench-$1.txt
}
(cd ufs2-probe/kern && tar cf - plain.img.xz eaonly.img.xz eaonly.expect) |
    $SSH 'mkdir -p /root/p && cd /root/p && tar xf -'
(cd out && tar cf - .) |
    $SSH 'mkdir -p /root/trunk && cd /root/trunk && tar xf -'
(cd ck && tar cf - chroot.sh atf.sh ck.sh bench.sh) | $SSH 'cd /root && tar xf -'

boot out/stock/netbsd.xz || exit 1
$SSH sh /root/chroot.sh stock
$SSH sh /root/atf.sh stock | tee atf-stock.txt
bench stock

for c in $STEPS; do
	boot out/$c/netbsd.xz || exit 1
	$SSH sh /root/chroot.sh patched
	bench $c
done

boot out/patched/netbsd.xz || exit 1
$SSH sh /root/chroot.sh patched
$SSH sh /root/atf.sh patched | tee atf-patched.txt
# Twice: a kernel that is not right may well show it only some of the
# time.  The kernel's messages from the whole of it are kept.
$SSH 'mkdir -p /t/tmp/p && cp /root/p/* /t/tmp/p/ && cp /root/ck.sh /t/tmp/ && /usr/sbin/chroot /t sh /tmp/ck.sh /tmp/p' 2>&1 | tee ck.txt
$SSH 'cd /t/tmp/ck/out && tar cf - .' > ck-out.tar
$SSH '/usr/sbin/chroot /t sh /tmp/ck.sh /tmp/p' 2>&1 | tee ck2.txt
$SSH dmesg 2>&1 | tail -150 | tee dmesg-ck.txt
bench patched
$SSH 'cd /root && tar cf - atf-stock atf-patched' > atf.tar

# The stock kernel again, to see how much the order of boots moves the
# numbers.
boot out/stock/netbsd.xz || exit 1
$SSH sh /root/chroot.sh stock
bench stock-again

mkdir -p res && tar xf atf.tar -C res
for n in fs_ffs sbin_fsck_ffs sbin_newfs sbin_resize_ffs; do
	for k in stock patched; do
		# tc, time, tp, tc, result, reason: drop the time
		grep '^tc,' res/atf-$k/$n.csv | cut -d, -f1,3- | sort > res/$n.$k.r
	done
	echo "--- $n stock vs patched"
	diff res/$n.stock.r res/$n.patched.r && echo identical
done | tee cmp.txt
{ echo '```'; cat atf-stock.txt atf-patched.txt cmp.txt ck.txt ck2.txt dmesg-ck.txt crash.txt bench-*.txt 2>/dev/null; echo '```'; } >> $GITHUB_STEP_SUMMARY

# Fail if a step gave nothing, rather than pass on empty results.
ok=0
for f in ck.txt ck2.txt; do
	grep -q '^\[cost\]' $f || { echo "$f incomplete"; ok=1; }
done
[ -s crash.txt ] && { echo "the guest panicked"; ok=1; }
tar tf ck-out.tar >/dev/null 2>&1 || { echo "no ck images"; ok=1; }
for f in bench-stock.txt bench-patched.txt bench-stock-again.txt; do
	grep -q 'plain write-512m' $f && grep -q 'files for fsck: .*files,' $f ||
	    { echo "$f incomplete"; ok=1; }
done
exit $ok
