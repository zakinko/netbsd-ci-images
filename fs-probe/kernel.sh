#!/bin/sh
# 測るカーネルを選ぶ。
#   kernel.sh rhel   Alma 10 のまま (何もしない)
#   kernel.sh ml     ELRepo の kernel-ml (kernel.org の最新 stable) を入れて
#                    既定にし、再起動する。戻ったら uname -r で確かめること。
set -e
case $1 in
rhel)
	uname -r
	;;
ml)
	rpm -q elrepo-release ||
		dnf -y -q install https://www.elrepo.org/elrepo-release-10.el10.elrepo.noarch.rpm
	dnf -y -q --enablerepo=elrepo-kernel install kernel-ml kernel-ml-core \
		kernel-ml-modules kernel-ml-modules-extra kernel-ml-devel
	k=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-ml-core | sort -V | tail -1)
	grubby --set-default /boot/vmlinuz-$k
	grubby --default-kernel
	echo "$k" > /var/tmp/want-kernel
	# 呼んだ側の ssh が先に閉じるよう、少し置いてから落とす。
	(sleep 5; systemctl reboot) > /dev/null 2>&1 &
	;;
esac
