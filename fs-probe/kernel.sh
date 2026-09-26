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
	# www.elrepo.org が VM の中で引けなかったことがある (run 36250762248)。
	# 同じものを elrepo.org の直の path から取り、何度かやり直す。
	r=https://elrepo.org/linux/elrepo/el10/x86_64/RPMS/elrepo-release-10.0-1.el10.elrepo.noarch.rpm
	for i in 1 2 3 4 5; do
		rpm -q elrepo-release > /dev/null && break
		dnf -y -q install $r || sleep 10
	done
	for i in 1 2 3; do
		dnf -y -q --enablerepo=elrepo-kernel install kernel-ml kernel-ml-core \
			kernel-ml-modules kernel-ml-modules-extra kernel-ml-devel && break
		sleep 10
	done
	k=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-ml-core | sort -V | tail -1)
	grubby --set-default /boot/vmlinuz-$k
	grubby --default-kernel
	echo "$k" > /var/tmp/want-kernel
	# action はこの後 workspace を host へ書き戻すので、それが済むまで
	# 置いてから落とす。
	setsid sh -c "sleep 30; systemctl reboot" < /dev/null > /dev/null 2>&1 &
	;;
esac
