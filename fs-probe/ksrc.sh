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
ufs_build() {	# logfile
	modprobe -r ufs 2>/dev/null
	make -C /lib/modules/$KV/build M=$ksrc/ufs CONFIG_UFS_FS=m \
		KCFLAGS=-DCONFIG_UFS_FS_WRITE=1 modules > $1 2>&1 &&
	insmod $ksrc/ufs/ufs.ko
}
