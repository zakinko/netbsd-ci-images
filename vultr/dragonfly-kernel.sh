#!/bin/sh
# DragonFly のゲストの中で、当て物を当てたカーネルを建てる。
# 木は /usr/src に、当て物を当てた状態で置いてあること。
#
# 出来上がりは /usr/obj/usr/src/sys/X86_64_GENERIC/kernel.stripped。
# make nativekernel は kernel という名前では置かないので、拾う側は
# stripped の方を見ること。
set -e
cd /usr/src
make -j$(sysctl -n hw.ncpu) nativekernel KERNCONF=X86_64_GENERIC
ls -l /usr/obj/usr/src/sys/X86_64_GENERIC/kernel.stripped
