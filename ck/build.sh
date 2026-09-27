#!/bin/sh
# Runs on the Ubuntu runner: build NetBSD amd64 twice.
#   stock:   trunk $REV
#   patched: $PREV, the head of the check-hash branch
# Each gives a GENERIC kernel and the base/etc/tests sets, in
# $W/out/{stock,patched}/.  The commits of the branch named in $STEPS
# also give a kernel each, in $W/out/<commit>/, to measure what each
# step of the branch costs.  The patched build is an update build on top
# of the stock one, so everything that the changed sources and headers
# reach is rebuilt, and only that.
set -eux
W=$(pwd)
REV=${REV:?}
PREV=${PREV:?}
STEPS=${STEPS:-}
nj=$(nproc)
mkdir -p out/stock out/patched
if [ ! -d src/.git ]; then
	git init -q src
	git -C src fetch -q --depth 1 https://github.com/zakinko/NetBSD-src $REV
	git -C src fetch -q --depth 30 https://github.com/zakinko/NetBSD-src $PREV
	git -C src checkout -q $REV
fi
V="-V MKX11=no -V MKDEBUG=no -V MKCOMPAT=no -V MKMAN=no -V MKHTML=no
   -V MKDOC=no -V MKINFO=no -V MKLINT=no -V MKPROFILE=no"
B="./build.sh -U -N1 -j$nj -m amd64 -O $W/obj -T $W/tools -D $W/dest -R $W/rel $V"
K=$W/obj/sys/arch/amd64/compile/GENERIC/netbsd
S=$W/rel/amd64/binary/sets
save() {	# label
	git -C $W/src log -1 --format='%H %cd' > $W/out/$1/rev
	xz -T0 -c $K > $W/out/$1/netbsd.xz
	cp $S/base.tar.xz $S/etc.tar.xz $S/tests.tar.xz $W/out/$1/
}
cd src
T=tools
[ -x $W/tools/bin/nbmake ] && T=
time $B $T kernel=GENERIC distribution sets
save stock
git checkout -q $PREV
git diff --stat $REV $PREV | tail -1
time $B -u kernel=GENERIC distribution sets
save patched
for c in $STEPS; do
	git checkout -q $c
	time $B -u kernel=GENERIC
	mkdir -p $W/out/$c
	git -C $W/src log -1 --format='%H %cd' > $W/out/$c/rev
	xz -T0 -c $K > $W/out/$c/netbsd.xz
done
cd $W/out
ls -lR; find . -type f | sort | xargs sha256sum | tee SHA256
