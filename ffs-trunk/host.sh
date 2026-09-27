#!/bin/sh
# Runs on the Ubuntu runner with amd64-11.0 up: trunk stock kernel,
# then trunk patched kernel, each with the VM test and the ATF runs.
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
(cd ufs2-probe/kern && tar cf - --exclude netbsd.xz .) |
    $SSH 'mkdir -p /root/p && cd /root/p && tar xf -'
(cd out && tar cf - base.tar.xz etc.tar.xz tests.tar.xz librumpfs_ffs.so.* fsck_ffs) |
    $SSH 'mkdir -p /root/trunk && cd /root/trunk && tar xf -'
$SSH 'cat > /root/atf.sh' < ffs-trunk/atf.sh
for k in stock patched; do
	boot out/netbsd.$k.xz || exit 1
	$SSH sh /root/p/guest.sh $k | tee kern-$k.txt
	$SSH sh /root/atf.sh $k | tee atf-$k.txt
done
$SSH 'cd /root/p/patched && tar cf - plain.img eaonly.img' > after.tar
$SSH 'cd /root && tar cf - atf-stock atf-patched' > atf.tar
mkdir -p res && tar xf atf.tar -C res
for n in fs_ffs sbin_fsck_ffs; do
	for k in stock patched; do
		# tc, time, tp, tc, result, reason: drop the time
		grep '^tc,' res/atf-$k/$n.csv | cut -d, -f1,3- | sort > res/$n.$k.r
	done
	echo "--- $n stock vs patched"
	diff res/$n.stock.r res/$n.patched.r && echo identical
done | tee cmp.txt
{ echo '```'; cat kern-stock.txt kern-patched.txt atf-stock.txt atf-patched.txt cmp.txt; echo '```'; } >> $GITHUB_STEP_SUMMARY
