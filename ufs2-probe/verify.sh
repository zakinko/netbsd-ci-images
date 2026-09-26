#!/bin/sh
# Check images that NetBSD has written against what FreeBSD recorded.
set -x
freebsd-version -ku
cd ufs2-probe/back || exit 1
for x in back-*.img.xz; do
	n=${x#back-}; n=${n%.img.xz}
	set +x
	echo "=================== $n"
	xz -dkf $x
	cp back-$n.img $n.img
	md=$(mdconfig -a -t vnode -f $n.img)
	dumpfs /dev/$md | grep -E '^flags|^check hashes'
	echo "--- fsck_ffs -n"
	fsck_ffs -n /dev/$md 2>&1
	echo "--- mount ro and compare"
	if mount -o ro /dev/$md /mnt; then
		ls -l /mnt
		while read f ino sum; do
			case $f in f*) ;; *) continue ;; esac
			if [ ! -e /mnt/$f ]; then echo "$f: MISSING"; continue; fi
			[ "$(sha256 -q /mnt/$f)" = "$sum" ] && d=ok || d=BAD
			p=$(getextattr -q user probe /mnt/$f 2>&1)
			[ "$p" = "attr-${f#f}-$sum" ] && e=ok || e="BAD($p)"
			echo "$f: data $d, extattr $e"
		done < $n.expect
		getextattr -q user big /mnt/f2 2>&1 | sha256 -q | sed 's/^/f2 big: /'
		getfacl -q /mnt/f1 2>&1 | sed 's/^/f1 acl /'
		umount /mnt
	fi
	echo "--- fsck_ffs -y"
	fsck_ffs -y /dev/$md 2>&1 | tail -15
	mdconfig -d -u $md
	set -x
done
