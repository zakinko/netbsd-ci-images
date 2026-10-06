#!/bin/sh
# Runs as root inside a trunk chroot: vndprobe.sh <label>
# ck.sh saw vnconfig hold the kernel lock for 10 seconds and more
# ("hogging kernel lock" from an ioctl).  Do the same steps here with a
# plain file system on any kernel, to see whether the stock one does it
# too: copy a 64 MB image onto tmpfs, write to it through vnd, detach.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
W=/tmp/vndprobe
M=$W/m
rm -rf $W; mkdir -p $M; cd $W || exit 1
now() { date +%s; }
echo "=== vndprobe $1: $(uname -v)"
dd if=/dev/zero of=a.img bs=1m count=64 2>/dev/null
newfs -F -s 64m -O2 a.img > /dev/null
seen=$(dmesg | wc -l)
for r in 1 2 3 4 5 6; do
	t0=$(now); cp a.img b.img; t1=$(now)
	vnconfig vnd3 b.img; t2=$(now)
	mount -t ffs /dev/vnd3a $M && {
		dd if=/dev/urandom of=$M/f bs=64k count=200 2>/dev/null
		mkdir $M/d; touch $M/d/x; sync
		umount $M
	}
	t3=$(now); vnconfig -u vnd3; t4=$(now)
	echo "$r cp $((t1 - t0))s vnconfig $((t2 - t1))s use $((t3 - t2))s vnconfig-u $((t4 - t3))s"
	mv b.img a.img
done
dmesg | tail -n +$((seen + 1)) | sed 's/^/  kernel: /'
rm -rf $W
