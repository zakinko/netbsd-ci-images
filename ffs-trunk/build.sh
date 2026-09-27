#!/bin/sh
# Runs on the Ubuntu runner: build NetBSD trunk amd64 twice over.
#   stock:   GENERIC kernel, base/etc/tests sets
#   patched: GENERIC kernel, librumpfs_ffs, fsck_ffs with both diffs
# Output goes to $W/out.
set -eux
W=$(pwd)
REV=${REV:?}
nj=$(nproc)
mkdir -p out
if [ ! -d src/.git ]; then
	git init -q src
	git -C src fetch -q --depth 1 https://github.com/zakinko/NetBSD-src $REV
	git -C src checkout -q FETCH_HEAD
fi
git -C src log -1 --format='%H %cd' | tee out/rev
V="-V MKX11=no -V MKDEBUG=no -V MKCOMPAT=no -V MKMAN=no -V MKHTML=no
   -V MKDOC=no -V MKINFO=no -V MKLINT=no -V MKPROFILE=no"
B="./build.sh -U -N1 -j$nj -m amd64 -O $W/obj -T $W/tools -D $W/dest -R $W/rel $V"
cd src
T=tools
[ -x $W/tools/bin/nbmake ] && T=
time $B $T kernel=GENERIC
K=$W/obj/sys/arch/amd64/compile/GENERIC/netbsd
cp $K $W/out/netbsd.stock
time $B distribution sets
cp $W/rel/amd64/binary/sets/base.tar.xz $W/rel/amd64/binary/sets/etc.tar.xz \
    $W/rel/amd64/binary/sets/tests.tar.xz $W/out/
for p in $W/ffs-trunk/*.diff; do git apply $p; done
git diff --stat
time $B -u kernel=GENERIC
cp $K $W/out/netbsd.patched
M=$W/tools/bin/nbmake-amd64
$M -C sys/rump/fs/lib/libffs dependall
$M -C sbin/fsck_ffs dependall
L=$(find $W/obj/sys/rump/fs/lib/libffs -name 'librumpfs_ffs.so.*.*' -type f)
cp $L $W/out/$(basename $L)
cp $W/obj/sbin/fsck_ffs/fsck_ffs $W/out/fsck_ffs
NM=$(ls $W/tools/bin/*-nm | head -1)
for f in $W/out/netbsd.stock $W/out/netbsd.patched $W/out/$(basename $L); do
	echo "$f: $($NM $f 2>/dev/null | grep -c ffs_fbsd_metackhash || true)"
done | tee $W/out/nm
cd $W/out
for f in netbsd.stock netbsd.patched; do xz -T0 $f; done
ls -l; sha256sum * | tee SHA256
