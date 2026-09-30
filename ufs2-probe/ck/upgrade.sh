#!/bin/sh
# Runs inside the guest as root: move it to one NetBSD-daily snapshot.
#   upgrade.sh <snap> kernel    kernel and modules only; reboot after
#   upgrade.sh <snap> userland  base, comp and tests, once the new
#                               kernel is running
# The userland goes in second: a -current sshd and shutdown under the
# old kernel stop answering, which is how the first try hung.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
SNAP=$1
B=https://nycdn.netbsd.org/pub/NetBSD-daily/HEAD/$SNAP/amd64/binary/sets
mkdir -p /root/sets && cd /root/sets || exit 1
get() { for s in "$@"; do [ -f $s.tar.xz ] || ftp -V -o $s.tar.xz $B/$s.tar.xz || exit 1; done; }
case $2 in
kernel)
	get kern-GENERIC modules
	tar -C / -xJpf modules.tar.xz || exit 1
	tar -C /root/sets -xJpf kern-GENERIC.tar.xz && cp /netbsd /netbsd.old && cp /root/sets/netbsd /netbsd || exit 1
	;;
userland)
	get base comp tests
	for s in base comp tests; do tar -C / -xJpf $s.tar.xz || exit 1; done
	# New connections after this run the new sshd with the old
	# /etc/ssh/sshd_config; show whether it accepts it while this
	# session is still open.
	/usr/sbin/sshd -V 2>&1 | head -1
	/usr/sbin/sshd -t; echo "sshd -t rc=$?"
	grep -vE '^#|^$' /etc/ssh/sshd_config
	ls /etc/ssh
	;;
*)	exit 2 ;;
esac
df -h /
