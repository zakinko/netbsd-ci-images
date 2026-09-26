#!/bin/sh
# AlmaLinux 10 の上で、NTFS と UFS の速さを ext4 / xfs と並べて測る。
#   bench.sh <indir> <outdir>
# indir には fs-probe の mk-netbsd / mk-freebsd が作ったイメージが在る。
#
# どれも同じ VM の同じディスク上の loop (direct-io=on) に置く。絶対値は
# runner と qemu の cache 次第なので、見るのは同じ回の中での比だけ。
set -u
in=$(cd "$1" && pwd)
mkdir -p "$2"
out=$(cd "$2" && pwd)
work=/var/tmp/fsb
mkdir -p $work /mnt/b
sum=$out/bench.txt
: > $sum
note() { printf '%s\n' "$*" | tee -a $sum; }
KV=$(uname -r)
REPS=3

note "# $(cat /etc/almalinux-release) / kernel $KV / $(nproc) cpu / $(free -m | awk '/Mem:/{print $2}')MB"
grep -E 'CONFIG_(LEGACY_DIRECT_IO|BUFFER_HEAD|FS_POSIX_ACL|FUSE_FS)[ =]' /lib/modules/$KV/config | tee -a $sum

dnf -y -q install epel-release
dnf -y -q install ntfs-3g ntfsprogs fio perf gcc make elfutils-libelf-devel \
	rpm cpio xz tar xfsprogs e2fsprogs bc kernel-headers
rpm -q ntfs-3g fio perf | tee -a $sum

here=$(cd "$(dirname "$0")" && pwd)
. $here/ksrc.sh
ufs_build $out/ufs-build.log
note "ufs build+insmod exit $?"
for m in ntfs3 ntfs; do
	modprobe $m 2>/dev/null && note "$m: $(modinfo -F filename $m)" || note "$m: not available"
done
dmesg -c > $out/dmesg-setup.txt

for f in $in/*.newfs; do
	note "--- $(basename $f)"
	grep -iE 'block size|bsize|fsize|frag' $f | head -3 | sed 's/^/    /' | tee -a $sum
done

drop() { sync; echo 3 > /proc/sys/vm/drop_caches; }
med() { sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }

# 一つの fs について、mount 済みの /mnt/b で測る。
run() {	# label
	l=$1
	sw=; sr=; rw=; cp=
	for i in $(seq $REPS); do
		drop
		fio --name=sw --directory=/mnt/b --rw=write --bs=1M --size=256M \
		    --end_fsync=1 --output-format=json > $work/sw.json 2>>$out/fio.err
		sw="$sw $(python3 -c 'import json,sys;j=json.load(open(sys.argv[1]));print(j["jobs"][0]["write"]["bw"]//1024)' $work/sw.json)"
		drop
		fio --name=sw --directory=/mnt/b --rw=read --bs=1M --size=256M \
		    --output-format=json > $work/sr.json 2>>$out/fio.err
		sr="$sr $(python3 -c 'import json,sys;j=json.load(open(sys.argv[1]));print(j["jobs"][0]["read"]["bw"]//1024)' $work/sr.json)"
		rm -f /mnt/b/sw.*
		drop
		fio --name=rw --directory=/mnt/b --rw=randwrite --bs=4k --size=64M \
		    --end_fsync=1 --output-format=json > $work/rw.json 2>>$out/fio.err
		rw="$rw $(python3 -c 'import json,sys;j=json.load(open(sys.argv[1]));print(j["jobs"][0]["write"]["iops"].__round__())' $work/rw.json)"
		rm -f /mnt/b/rw.*
		drop
		t0=$(date +%s.%N)
		cp -a /usr/include /mnt/b/inc 2>>$out/cp.err
		sync
		t1=$(date +%s.%N)
		cp="$cp $(echo "$t1 - $t0" | bc)"
		rm -rf /mnt/b/inc; sync
	done
	note "$(printf '%-22s seqwrite %5s MB/s  seqread %5s MB/s  rand4k %6s IOPS  cp-include %6ss' "$l" \
		"$(echo $sw | tr ' ' '\n' | med)" "$(echo $sr | tr ' ' '\n' | med)" \
		"$(echo $rw | tr ' ' '\n' | med)" "$(echo $cp | tr ' ' '\n' | med)")"
	# 書き込み一回あたりの I/O の大きさ。loop の stat の 5 番目が書き込み
	# 回数、7 番目が書いた sector 数 (Documentation/block/stat.rst)。
	dev=$(basename $(findmnt -no SOURCE /mnt/b))
	drop
	set -- $(cat /sys/block/$dev/stat); w0=$5; s0=$7
	fio --name=sw --directory=/mnt/b --rw=write --bs=1M --size=256M \
	    --end_fsync=1 > /dev/null 2>>$out/fio.err
	set -- $(cat /sys/block/$dev/stat); w1=$5; s1=$7
	rm -f /mnt/b/sw.*
	note "$(printf '%-22s   seqwrite I/O: %s writes, avg %s KiB' '' $((w1 - w0)) $(( (s1 - s0) / 2 / ((w1 - w0) > 0 ? (w1 - w0) : 1) )))"
	note "$(printf '%-22s   runs: sw[%s ] sr[%s ] rw[%s ] cp[%s ]' '' "$sw" "$sr" "$rw" "$cp")"
}
# perf で書き込みの中身を見る。
prof() {	# label
	drop
	perf record -q -a -g -o $work/perf.data -- \
		fio --name=sw --directory=/mnt/b --rw=write --bs=1M --size=256M \
		--end_fsync=1 > /dev/null 2>&1
	perf report -q -i $work/perf.data --no-children --sort symbol \
		--percent-limit 1.5 --stdio 2>/dev/null | grep -E '^ +[0-9]' | head -25 > $out/perf-$1.txt
	rm -f /mnt/b/sw.* $work/perf.data
	note "perf $1 (self, top):"
	sed -n '1,12p' $out/perf-$1.txt | sed 's/^/    /' | tee -a $sum
}
blank() {	# file
	rm -f $1; truncate -s 1G $1
	loop=$(losetup -f --show --direct-io=on $1)
}
done_loop() { umount /mnt/b; losetup -d $loop; rm -f $work/*.raw; }

note ""
note "## results (median of $REPS)"
blank $work/x.raw; mkfs.ext4 -q $loop && mount $loop /mnt/b && run ext4; done_loop
blank $work/x.raw; mkfs.xfs -q $loop && mount $loop /mnt/b && run xfs; done_loop
for m in ntfs3 ntfs; do
	grep -qw $m /proc/filesystems || continue
	blank $work/x.raw; mkntfs -Q -q $loop && mount -i -t $m $loop /mnt/b && [ "$(findmnt -no FSTYPE /mnt/b)" = $m ] && run $m; done_loop
done
blank $work/x.raw; mkntfs -Q -q $loop && ntfs-3g $loop /mnt/b && run ntfs-3g; done_loop
blank $work/x.raw; mkntfs -Q -q $loop && ntfs-3g -o big_writes $loop /mnt/b && run 'ntfs-3g big_writes'; done_loop
blank $work/x.raw; mkntfs -Q -q $loop && ntfs-3g -o noatime,big_writes,max_read=1048576 $loop /mnt/b && run 'ntfs-3g tuned'; done_loop

for n in netbsd-ffs2 netbsd-ffs1 freebsd-ufs2 freebsd-ufs1; do
	[ -e $in/$n.img ] || continue
	case $n in *ffs1|*ufs1) t=44bsd ;; *) t=ufs2 ;; esac
	cp --sparse=always $in/$n.img $work/u.img
	rm -rf /mnt/b/src 2>/dev/null
	# 7.x の loop は direct-io のとき論理 sector を下の fs の block (4096)
	# に揃える。ufs は superblock を 1024 で読むので、そこで
	# "failed to set blocksize" になり mount できない (run 36257259132)。
	# 4K sector で断られることを一度記録してから、512 で測る。
	loop=$(losetup -f --show --direct-io=on $work/u.img)
	note "ufs $n on $(cat /sys/block/$(basename $loop)/queue/logical_block_size)-byte sectors: $(mount -t ufs -o ro,ufstype=$t $loop /mnt/b 2>&1 && { umount /mnt/b; echo mounts; } || echo 'does not mount')"
	losetup -d $loop
	loop=$(losetup -f --show --direct-io=on -b 512 $work/u.img)
	mount -t ufs -o rw,ufstype=$t $loop /mnt/b && rm -rf /mnt/b/src && sync && {
		df -k /mnt/b | tail -1 | sed 's/^/    /' | tee -a $sum
		run "ufs $n"
		prof "ufs-$n"
	}
	umount /mnt/b; losetup -d $loop; rm -f $work/u.img
done
blank $work/x.raw; mkfs.ext4 -q $loop && mount $loop /mnt/b && prof ext4; done_loop
blank $work/x.raw; mkntfs -Q -q $loop && ntfs-3g $loop /mnt/b && prof ntfs-3g; done_loop
for m in ntfs3 ntfs; do
	grep -qw $m /proc/filesystems || continue
	blank $work/x.raw; mkntfs -Q -q $loop && mount -i -t $m $loop /mnt/b && [ "$(findmnt -no FSTYPE /mnt/b)" = $m ] && prof $m; done_loop
done

dmesg > $out/dmesg-end.txt
note ""
note "fio errors: $(wc -l < $out/fio.err)  cp errors: $(wc -l < $out/cp.err 2>/dev/null || echo 0)"
sed -n '1,10p' $out/cp.err 2>/dev/null | sed 's/^/    /' | tee -a $sum
