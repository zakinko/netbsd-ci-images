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
		n=$((n+1)); [ $n -gt 60 ] && return 1; sleep 5
	done
	$SSH uname -v
}
bench() {	# label
	$SSH "cp /root/bench.sh /t/tmp/ && chroot /t sh /tmp/bench.sh $1 /tmp/tests.tar" 2>&1 |
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
$SSH 'mkdir -p /t/tmp/p && cp /root/p/* /t/tmp/p/ && cp /root/ck.sh /t/tmp/ && chroot /t sh /tmp/ck.sh /tmp/p' 2>&1 | tee ck.txt
$SSH 'cd /t/tmp/ck/out && tar cf - .' > ck-out.tar
bench patched
$SSH 'cd /root && tar cf - atf-stock atf-patched' > atf.tar

mkdir -p res && tar xf atf.tar -C res
for n in fs_ffs sbin_fsck_ffs sbin_newfs sbin_resize_ffs; do
	for k in stock patched; do
		# tc, time, tp, tc, result, reason: drop the time
		grep '^tc,' res/atf-$k/$n.csv | cut -d, -f1,3- | sort > res/$n.$k.r
	done
	echo "--- $n stock vs patched"
	diff res/$n.stock.r res/$n.patched.r && echo identical
done | tee cmp.txt
{ echo '```'; cat atf-stock.txt atf-patched.txt cmp.txt ck.txt bench-*.txt; echo '```'; } >> $GITHUB_STEP_SUMMARY
