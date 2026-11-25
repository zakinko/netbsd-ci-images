#!/bin/sh
in=$1 out=$2 label=$3
here=$(cd "$(dirname "$0")/.." && pwd)
w=/run/w
mkdir -p "$out" $w && mount -t tmpfs -o size=3g none $w && mkdir $w/m
sum=$out/$label.txt; : > $sum
note() { printf '%s\n' "$*" | tee -a $sum; }
note "# $label kernel $(uname -r) $(uname -v)"
. $here/send/ufs-zsync-guest.inc
zsync vda netbsd-ffs2
zsync vdb freebsd-ufs2
