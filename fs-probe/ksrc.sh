# . で読む。走っているカーネルと同じ版の fs/ ソースを $work の下に広げ、
# その path を $ksrc に置く。kernel-devel (ELRepo なら kernel-ml-devel) も
# ここで揃える。
KV=$(uname -r)
case $KV in
*elrepo*)
	# kernel-ml は kernel.org の stable をそのまま包んだもの。
	kver=${KV%%-*}
	dnf -y -q install kernel-ml-devel-$KV 2>/dev/null ||
		rpm -q kernel-ml-devel-$KV
	(cd $work && curl -fsSL -o linux.tar.xz \
		https://cdn.kernel.org/pub/linux/kernel/v${kver%%.*}.x/linux-$kver.tar.xz &&
	 tar -xJf linux.tar.xz "linux-$kver/fs/ufs" "linux-$kver/fs/ntfs3" "linux-$kver/fs/ntfs")
	ksrc=$work/linux-$kver/fs
	;;
*)
	rel=$(echo $KV | sed -n 's/.*\.el10_\([0-9]*\)\..*/10.\1/p')
	v=${KV%.x86_64}
	if ! dnf -y -q install kernel-devel-$KV; then
		for u in https://vault.almalinux.org/$rel/AppStream/x86_64/os/Packages \
		         https://repo.almalinux.org/almalinux/$rel/AppStream/x86_64/os/Packages; do
			rpm -ivh --nodeps $u/kernel-devel-$v.x86_64.rpm && break
		done
	fi
	(cd $work &&
	 for u in https://vault.almalinux.org/$rel/BaseOS/Source/Packages \
	          https://repo.almalinux.org/almalinux/$rel/BaseOS/Source/Packages; do
		curl -fsSL -o k.src.rpm $u/kernel-$v.src.rpm && break
	 done &&
	 rpm2cpio k.src.rpm | cpio -idm --quiet 'linux-*.tar.xz' &&
	 tar -xJf linux-*.tar.xz --wildcards '*/fs/ufs/*' '*/fs/ntfs3/*')
	ksrc=$(echo $work/linux-*/fs)
	;;
esac

# 出荷の ufs は UFS_FS_WRITE が無い (kernel-ml) か、そもそも無い (RHEL)。
# 書き込みを有効にしたものを建てて差し替える。UFS_FS_WRITE は C の
# #ifdef で見られるだけなので、-D で渡せば足りる。
# 警告は一番厳しい W=123 で取る。既存のコードが元から出す警告は直さない
# ので、当てる前と後で並べ、当てた後にだけ出るもの (行と桁を伏せて比べる)
# を数える。それが 0 でなければ建てたことにしない。
ufs_make() {	# logfile
	make -C /lib/modules/$KV/build M=$ksrc/ufs CONFIG_UFS_FS=m W=123 \
		KCFLAGS=-DCONFIG_UFS_FS_WRITE=1 modules > $1 2>&1
}
ufs_warnings() {	# logfile
	grep -E 'warning:' $1 | sed -E 's/:[0-9]+:[0-9]+:/:/' | LC_ALL=C sort -u
}

# UFS_PATCH=1 なら fs-probe/patches/ufs-*.patch を当ててから建てる。
# 当たらなければ建てない (当たらないまま測ると、直した物を測った
# ことにならない)。
ufs_build() {	# logfile
	modprobe -r ufs 2>/dev/null
	if [ "${UFS_PATCH:-0}" = 1 ]; then
		ufs_make $1.base || { cat $1.base; return 1; }
		make -C /lib/modules/$KV/build M=$ksrc/ufs clean > /dev/null 2>&1
		for p in $here/patches/ufs-*.patch; do
			(cd $(dirname $ksrc) && patch -p1 -f -i $p < /dev/null) > $1.patch 2>&1 ||
				{ cat $1.patch; return 1; }
			grep -qi 'fuzz\|offset' $1.patch && cat $1.patch
			echo "patched: $(basename $p)"
		done
	fi
	ufs_make $1 || { tail -20 $1; return 1; }
	if [ "${UFS_PATCH:-0}" = 1 ]; then
		ufs_warnings $1.base > $1.w-base
		ufs_warnings $1 > $1.w-patched
		comm -13 $1.w-base $1.w-patched > $1.w-new
		echo "W=123 warnings: before $(wc -l < $1.w-base), after $(wc -l < $1.w-patched), new $(wc -l < $1.w-new)"
		cat $1.w-new
		[ -s $1.w-new ] && return 1
	fi
	insmod $ksrc/ufs/ufs.ko
}
