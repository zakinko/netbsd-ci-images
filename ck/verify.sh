#!/bin/sh
# Runs on FreeBSD: check the images that the check-hash kernel and
# fsck_ffs wrote.  FreeBSD's fsck_ffs verifies every check-hash it
# reads; its mount verifies the superblock's, and reading the files
# verifies the inodes'.
freebsd-version -ku
cd ck/out || exit 1
for img in *.img; do
	n=${img%.img}
	echo "=================== $n"
	md=$(mdconfig -a -t vnode -f $img)
	dumpfs /dev/$md | grep -E '^flags|^check hashes'
	echo "--- fsck_ffs -n"
	fsck_ffs -n /dev/$md 2>&1
	echo "--- mount ro and compare"
	if mount -o ro /dev/$md /mnt; then
		if [ -f $n.sums ]; then
			(cd /mnt && find . -type f ! -path './.snap/*' |
			    LC_ALL=C sort | xargs sha256) > $n.got
			if cmp -s $n.sums $n.got; then
				echo "files: $(wc -l < $n.got) all match"
			else
				echo "files: DIFFER"; diff $n.sums $n.got | head -20
			fi
		else
			find /mnt -type f | wc -l | sed 's/^/files (no manifest): /'
		fi
		ok=0; bad=0
		while read f ino sum; do
			case $f in f*) ;; *) continue ;; esac
			[ -e /mnt/$f ] || continue
			p=$(getextattr -q user probe /mnt/$f 2>/dev/null)
			if [ "$p" = "attr-${f#f}-$sum" ] &&
			    [ "$(sha256 -q /mnt/$f)" = "$sum" ]; then
				ok=$((ok + 1))
			else
				bad=$((bad + 1)); echo "$f: BAD data or extattr"
			fi
		done < ../../ufs2-probe/kern/eaonly.expect
		[ $ok -gt 0 ] && echo "FreeBSD files with extattrs: $ok ok, $bad bad"
		umount /mnt
	fi
	mdconfig -d -u $md
done
