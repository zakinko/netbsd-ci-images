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
	# elrepo.org は VM の中の resolver から引けない (run 36250762248 と
	# 36251789374 で、EPEL や vault は引けるのにこの名前だけ落ちた)。
	# rpm は host で fsp/rpms に落としてあるので、それを入れる。
	dnf -y -q install fsp/rpms/kernel-ml*.rpm
	k=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-ml-core | sort -V | tail -1)
	grubby --set-default /boot/vmlinuz-$k
	grubby --default-kernel
	echo "$k" > /var/tmp/want-kernel
	# action はこの後 workspace を host へ書き戻すので、それが済むまで
	# 置いてから落とす。
	setsid sh -c "sleep 30; systemctl reboot" < /dev/null > /dev/null 2>&1 &
	;;
esac
