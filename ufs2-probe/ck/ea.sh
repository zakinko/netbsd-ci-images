#!/bin/sh
# Runs inside the guest as root: ea.sh <label>
# The magic of every superblock copy after newfs -O 2ea and after
# fsck_ffs -c ea / -c no-ea, native and -B be, with whatever newfs and
# fsck_ffs are installed.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
mkdir -p /root/p/ea && cd /root/p/ea || exit 1
mk() { rm -f m.img; dd if=/dev/zero of=m.img bs=1m count=0 seek=256 2>/dev/null; newfs -F -s 512m $1 m.img >/dev/null || echo NEWFS-FAIL; }
chk() { r=$(fsck_ffs -n -f m.img 2>&1 | grep -E 'ALTERNATE|BAD SUPER|files' | head -1); printf '%-24s %s\n' "$1" "$r"; sh /root/p/ck/alt.sh m.img 2>/dev/null | awk '{print "    "$1" "$2" alts "$4" .. "$NF" ("NF-3")"}'; }
echo "== $1: $(cksum -a sha256 /sbin/newfs /sbin/fsck_ffs | awk '{print $2" "substr($4,1,12)}' | tr '\n' ' ')"
for B in "" "-B be"; do
	mk "-O 2ea $B"; chk "newfs -O 2ea $B"
	mk "-O 2 $B"; fsck_ffs -y -f -c ea m.img >/dev/null 2>&1; chk "fsck -c ea $B"
	mk "-O 2ea $B"; fsck_ffs -y -f -c no-ea m.img >/dev/null 2>&1; chk "fsck -c no-ea $B"
done
