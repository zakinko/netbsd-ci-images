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
# fs ごとの Kconfig。C の #ifdef でしか見られないものは KCFLAGS で -D する。
fs_config() {	# fs
	case $1 in
	ufs)	echo CONFIG_UFS_FS=m KCFLAGS=-DCONFIG_UFS_FS_WRITE=1 ;;
	ntfs3)	echo CONFIG_NTFS3_FS=m CONFIG_NTFS3_LZX_XPRESS=y \
		     KCFLAGS=-DCONFIG_NTFS3_LZX_XPRESS=1 ;;
	esac
}

# 警告は一番厳しい W=123 で取る。既存のコードが元から出す警告は直さない
# ので、当てる前と後で並べ、当てた後にだけ出るもの (行と桁を伏せて比べる)
# を数える。それが 0 でなければ建てたことにしない。
fs_make() {	# fs logfile
	make -C /lib/modules/$KV/build M=$ksrc/$1 $(fs_config $1) W=123 \
		modules > $2 2>&1
}
fs_warnings() {	# logfile
	grep -E 'warning:' $1 | sed -E 's/:[0-9]+:[0-9]+:/:/' | LC_ALL=C sort -u
}

# FS_PATCH=1 なら fs-probe/patches/<fs>-*.patch を当ててから建てる。
# 当たらなければ建てない (当たらないまま測ると、直した物を測った
# ことにならない)。建てたものは、同じ名前の出荷のモジュールと差し替える。
fs_build() {	# fs logfile
	fs=$1 log=$2
	modprobe -r $fs 2>/dev/null
	if [ "${FS_PATCH:-0}" = 1 ]; then
		fs_make $fs $log.base || { cat $log.base; return 1; }
		make -C /lib/modules/$KV/build M=$ksrc/$fs clean > /dev/null 2>&1
		for p in $here/patches/$fs-*.patch; do
			[ -e "$p" ] || continue
			(cd $(dirname $ksrc) && patch -p1 -f -i $p < /dev/null) \
				> $log.patch 2>&1 || { cat $log.patch; return 1; }
			grep -qi 'fuzz\|offset' $log.patch && cat $log.patch
			echo "patched: $(basename $p)"
		done
	fi
	fs_make $fs $log || { tail -20 $log; return 1; }
	if [ "${FS_PATCH:-0}" = 1 ]; then
		fs_warnings $log.base > $log.w-base
		fs_warnings $log > $log.w-patched
		comm -13 $log.w-base $log.w-patched > $log.w-new
		echo "$fs W=123 warnings: before $(wc -l < $log.w-base), after $(wc -l < $log.w-patched), new $(wc -l < $log.w-new)"
		cat $log.w-new
		[ -s $log.w-new ] && return 1
	fi
	insmod $ksrc/$fs/$fs.ko
}
