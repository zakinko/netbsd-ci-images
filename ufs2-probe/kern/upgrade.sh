#!/bin/sh
# Runs inside the 11.0 guest as root: move it to one NetBSD-daily snapshot.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
SNAP=$1
B=https://nycdn.netbsd.org/pub/NetBSD-daily/HEAD/$SNAP/amd64/binary/sets
mkdir -p /root/sets && cd /root/sets || exit 1
df -h /
for s in base comp modules tests kern-GENERIC; do
	ftp -V -o $s.tar.xz $B/$s.tar.xz || exit 1
done
ls -l
for s in base comp modules tests; do tar -C / -xJpf $s.tar.xz || exit 1; done
tar -C /root/sets -xJpf kern-GENERIC.tar.xz && cp /root/sets/netbsd /netbsd || exit 1
rm -f /root/sets/*.tar.xz
df -h /
