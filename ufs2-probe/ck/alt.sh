#!/bin/sh
# print the magic of every superblock copy: alt.sh <img>
img=$1
set -- $(/usr/sbin/dumpfs "$img" | awk '/^sblkno/{print $2} /^fsize/{print $4} /^fpg/{print $2} /^ncg/{print $2}' | tr '\n' ' ')
eval $(/usr/sbin/dumpfs "$img" | awk '/^sblkno/{printf "sb=%s ",$2} /fsize/{for(i=1;i<NF;i++) if($i=="fsize") printf "fs=%s ",$(i+1)} /^fpg/{printf "fpg=%s ",$2} /^ncg/{printf "ncg=%s ",$2}')
c=0; out=""
while [ $c -lt $ncg ]; do
  off=$(( (c*fpg+sb)*fs + 1372 ))
  out="$out $(od -A n -t x4 -j $off -N 4 "$img" | tr -d ' ')"
  c=$((c+1))
done
echo "primary $(od -A n -t x4 -j $((65536+1372)) -N 4 "$img" | tr -d ' ') alts$out"
