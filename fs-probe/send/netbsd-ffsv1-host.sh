#!/bin/bash
# NetBSD の FFSv1 の日付の試験を、runner の上の qemu で回す。
#	netbsd-ffsv1-host.sh test <建てたものの dir>	ctl, new, old (在れば nonfs も) を boot する
#	netbsd-ffsv1-host.sh back <建てたものの dir>	FreeBSD が触った image を読む
#	netbsd-ffsv1-host.sh check			結果を数える。合わなければ落ちる
# 記録は ./res に、FreeBSD に渡す image は ./fbin に置く。大きなものは
# $HOME の直下に置く。vmactions は /home/runner/work を丸ごと FreeBSD の VM へ
# 写すので、その下 ($RUNNER_TEMP も) に root の持ち物の木を置くと rsync が落ちる。
set -u
stage=$1
HERE=$(cd "$(dirname "$0")" && pwd)
W=${FFSV1_WORK:-$HOME/ffsv1-test}
RES=$PWD/res
mkdir -p "$W" "$RES"
B=https://nycdn.netbsd.org/pub/NetBSD-daily/HEAD/latest/amd64/binary

setup() {
	IN=$(realpath "$1")
	[ -d $W/root ] && return
	sudo apt-get -q update > /dev/null; sudo apt-get -qy install qemu-system-x86 e2fsprogs > /dev/null
	sudo chmod 666 /dev/kvm
	mkdir -p $W/root $W/k
	for s in base rescue etc; do curl -sSfL $B/sets/$s.tar.xz | sudo tar -xJpf - -C $W/root; done
	curl -sSfL $B/sets/kern-GENERIC.tar.xz | tar -xJf - -C $W/k; mv $W/k/netbsd $W/netbsd-old
	gunzip -c $IN/netbsd.gz > $W/netbsd-new
	[ -f $IN/netbsd-nonfs.gz ] && gunzip -c $IN/netbsd-nonfs.gz > $W/netbsd-nonfs
	sudo mkdir -p $W/root/new $W/root/mnt $W/root/w $W/root/nfs $W/root/atf
	sudo cp $IN/bin/* $W/root/new/
	[ -d $IN/lib ] && sudo cp $IN/lib/* $W/root/new/
	[ -d $IN/atf ] && sudo cp $IN/atf/* $W/root/atf/
	sudo chmod 755 $W/root/new/* $W/root/atf/* 2> /dev/null
	sudo cp $HERE/netbsd-ffsv1-rc $W/root/etc/rc
	ls -l $W/root/new $W/root/atf
}

boot() {	# 何をするか カーネル ディスク...
	mode=$1; kern=$2; shift 2
	echo $mode | sudo tee $W/root/testkernel > /dev/null
	rm -f $W/root.raw; truncate -s 1800M $W/root.raw
	sudo mke2fs -q -t ext2 -O none,filetype,sparse_super -I 128 -b 4096 -d $W/root -F $W/root.raw
	sudo chmod 666 $W/root.raw
	D="-drive if=virtio,format=raw,file=$W/root.raw"
	for f in "$@"; do D="$D -drive if=virtio,format=raw,file=$f"; done
	timeout 1200 qemu-system-x86_64 -M q35 -enable-kvm -cpu host -smp 2 -m 2048 \
	    -kernel $W/netbsd-$kern -append "console=com root=ld0d rw -v" $D \
	    -display none -serial file:$RES/$mode.log -monitor none -no-reboot || echo "qemu exit $?"
	echo "##### $mode"
	tr -d '\r' < $RES/$mode.log | grep -a '^T' || tail -60 $RES/$mode.log
	rm -f $W/root.raw
}

count() {	# 記録 正規表現
	tr -d '\r' < $RES/$1.log 2> /dev/null | grep -acE "$2"
}

case $stage in
test)
	setup "$2"
	for i in 1 2 3 4; do truncate -s 128M $W/c$i.raw $W/d$i.raw; done
	boot ctl old $W/c1.raw $W/c2.raw $W/c3.raw $W/c4.raw
	boot new new $W/d1.raw $W/d2.raw $W/d3.raw $W/d4.raw
	boot old old $W/d1.raw $W/d2.raw $W/d3.raw $W/d4.raw
	[ -f $W/netbsd-nonfs ] && boot nonfs nonfs $W/c1.raw $W/c2.raw $W/c3.raw $W/c4.raw
	mkdir -p fbin
	for i in 1 2 3; do gzip -c $W/d$i.raw > $RES/d$i.raw.gz; done
	cp $RES/d1.raw.gz $RES/d2.raw.gz fbin/
	;;
back)
	setup "$2"
	n=0
	for f in d1-2026 d1-2040 d2-2026 d2-2040; do
		n=$((n + 1))
		if [ -s fbout/$f.raw.gz ]; then
			gunzip -c fbout/$f.raw.gz > $W/b$n.raw; cp fbout/$f.raw.gz $RES/fb-$f.raw.gz
		else
			echo "no fbout/$f.raw.gz"; truncate -s 128M $W/b$n.raw
		fi
	done
	[ -f fbout/fbsd.log ] && cp fbout/fbsd.log $RES/
	boot back new $W/b1.raw $W/b2.raw $W/b3.raw $W/b4.raw
	;;
check)
	bad=0
	want() {	# 記録 正規表現 件数 説明
		got=$(count $1 "$2")
		if [ "$got" = "$3" ]; then echo "ok   $4: $got"; else echo "FAIL $4: $got, expected $3"; bad=1; fi
	}
	for m in ctl new old back; do want $m '^T ALLDONE$' 1 "$m ran to the end"; done
	want new '^T .*(newfs failed|mount failed)' 0 "new: newfs and mount"
	want new ' cached w2040 2209086245 ' 3 "new: 2040 before remount"
	want new ' remounted w2040 2209086245 ' 3 "new: 2040 after remount"
	want new ' restored w2040 2209086245 ' 3 "new: 2040 through dump and restore"
	want new ' remounted badnsec[-0-9]* 2209086245 ' 15 "new: seconds kept with bad nanoseconds"
	want new '^T ffsv1-.* fsck exit 0 ' 3 "new: fsck_ffs clean"
	want new '^T makefs-.. m2040 2209086245 ' 2 "new: makefs 2040"
	want new '^T atf ufs1time_[a-z]* exit 0 result passed' 3 "new: ATF passed"
	want ctl '^T atf ufs1time_[a-z]* exit 0 result passed' 0 "ctl: ATF does not pass unpatched"
	want new '^T nfs-ffsv1 exclusive create: ok 40 failed 0 ' 1 "new: NFS exclusive create on FFSv1"
	want new '^T nfs-ffsv1 same verifier twice, .*: first 0 again 0' 5 "new: NFS exclusive create repeated on FFSv1"
	want new '^T nfs-ffsv2 same verifier twice, .*: first 0 again 0' 5 "new: NFS exclusive create repeated on FFSv2"
	want new '^T nfs-ext2fs same verifier twice, .*: first 0 again 0' 5 "new: NFS exclusive create repeated on ext2fs"
	want ctl '^T nfs-ffsv1 same verifier twice, .*: first 0 again 0' 5 "ctl: NFS exclusive create repeated on FFSv1"
	if [ -f $RES/nonfs.log ]; then
		want nonfs '^T ALLDONE$' 1 "nonfs ran to the end"
		want nonfs '^T nfs-ffsv1 same verifier twice, .*: first 0 again 17' 3 "nonfs: without the nfs_serv.c change three of the five are refused on FFSv1"
	fi
	want old ' remounted w2030 1893553445 ' 3 "old: 2030 written by new"
	exit $bad
	;;
esac
