#!/bin/sh
# Runs inside the guest as root: swapk.sh <dir>  install <dir>/netbsd.xz as /netbsd
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
cd /root/p/ck || exit 1
[ -f /netbsd.stock ] || cp /netbsd /netbsd.stock
xz -dc $1/netbsd.xz > /netbsd && cksum -a sha256 /netbsd
