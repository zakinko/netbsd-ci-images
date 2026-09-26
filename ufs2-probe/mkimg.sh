#!/bin/sh
# Make FreeBSD UFS2 images for probing NetBSD's handling of them.
set -ex
freebsd-version -ku
mkdir -p out

mk() {	# name newfs-args...
	name=$1; shift
	truncate -s 64m out/$name.img
	md=$(mdconfig -a -t vnode -f out/$name.img)
	newfs "$@" /dev/$md
	echo $md > out/$name.md
}
fin() {	# name
	name=$1; md=$(cat out/$name.md)
	dumpfs /dev/$md | head -25 > out/$name.dumpfs
	mdconfig -d -u $md
	rm out/$name.md
}

# plain: what a bare newfs gives
mk plain
md=$(cat out/plain.md)
mount /dev/$md /mnt && echo hello > /mnt/hello && umount /mnt
fin plain

# ea: extended attributes and a POSIX.1e ACL, plus data around them
mk ea
md=$(cat out/ea.md)
tunefs -a enable /dev/$md
mount /dev/$md /mnt
for i in 1 2 3 4 5 6 7 8; do
	dd if=/dev/random of=/mnt/f$i bs=64k count=4 2>/dev/null
	setextattr user probe "attr-$i-$(sha256 -q /mnt/f$i)" /mnt/f$i
done
setfacl -m u:nobody:rwx /mnt/f1
dd if=/dev/random bs=1 count=3000 2>/dev/null | b64encode - | tail -n +2 > out/big.tmp
setextattr -i user big /mnt/f2 < out/big.tmp
rm out/big.tmp /mnt/f4 /mnt/f6		# leave holes for reuse
(cd /mnt && for f in f*; do
	echo "$f $(ls -i $f | awk '{print $1}') $(sha256 -q $f)"
	echo "  probe=$(getextattr -q user probe $f)"
	echo "  big=$(getextattr -q user big $f 2>/dev/null | sha256 -q)"
	getfacl -q $f | sed 's/^/  acl /'
done) > out/ea.expect
cat out/ea.expect
umount /mnt
fin ea

# eaonly: extended attributes without the ACL flag
mk eaonly
md=$(cat out/eaonly.md)
mount /dev/$md /mnt
for i in 1 2 3 4 5 6 7 8; do
	dd if=/dev/random of=/mnt/f$i bs=64k count=4 2>/dev/null
	setextattr user probe "attr-$i-$(sha256 -q /mnt/f$i)" /mnt/f$i
done
dd if=/dev/random bs=1 count=3000 2>/dev/null | b64encode - | tail -n +2 > out/big.tmp
setextattr -i user big /mnt/f2 < out/big.tmp
rm out/big.tmp
(cd /mnt && for f in f*; do
	echo "$f $(ls -i $f | awk '{print $1}') $(sha256 -q $f)"
	echo "  probe=$(getextattr -q user probe $f)"
	echo "  big=$(getextattr -q user big $f 2>/dev/null | sha256 -q)"
done) > out/eaonly.expect
cat out/eaonly.expect
umount /mnt
fin eaonly

# suj: what bsdinstall does (newfs -U -j)
mk suj -U -j
md=$(cat out/suj.md)
mount /dev/$md /mnt && echo hello > /mnt/hello && umount /mnt
fin suj

cat out/*.dumpfs
cd out && for f in *.img; do xz -k $f; done
