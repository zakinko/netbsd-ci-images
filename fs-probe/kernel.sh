#!/bin/sh
# 測るカーネルを選ぶ。
#   kernel.sh rhel   Alma 10 のまま。起動の引数だけ足して再起動する。
#   kernel.sh ml     ELRepo の kernel-ml (kernel.org の最新 stable) を入れて
#                    既定にし、再起動する。戻ったら uname -r で確かめること。
set -e
# 入れ子の AMD KVM の上では、user shadow stack の xsave 状態が揃わない。
# run 41490343394 の rhel で、fwupd の fork が fpu_clone と ssp_get で WARN
# を出し、続いて systemd、sshd ほかが control protection で死んで、VM に
# 入れなくなった。測る物と関係が無いので、どちらの kernel でも切る。
grubby --update-kernel=ALL --args=nousershstk
case $1 in
rhel)
	uname -r
	setsid sh -c "sleep 30; systemctl reboot" < /dev/null > /dev/null 2>&1 &
	;;
ml)
	# elrepo.org は VM の中の resolver から引けない (run 36250762248 と
	# 36251789374 で、EPEL や vault は引けるのにこの名前だけ落ちた)。
	# rpm は host で fsp/rpms に落としてあるので、それを入れる。
	# ミラーから来た物なので、elrepo-release に入っている鍵で署名を確かめる。
	dnf -y -q install fsp/rpms/elrepo-release-*.rpm
	for k in /etc/pki/rpm-gpg/RPM-GPG-KEY-*elrepo*; do rpm --import $k; done
	rpm -K fsp/rpms/kernel-ml*.rpm
	rpm -K fsp/rpms/kernel-ml*.rpm | grep -v ': digests signatures OK$' && exit 1
	dnf -y -q install fsp/rpms/kernel-ml*.rpm
	k=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-ml-core | sort -V | tail -1)
	grubby --set-default /boot/vmlinuz-$k
	grubby --update-kernel=/boot/vmlinuz-$k --args=nousershstk
	grubby --default-kernel
	echo "$k" > /var/tmp/want-kernel
	# action はこの後 workspace を host へ書き戻すので、それが済むまで
	# 置いてから落とす。
	setsid sh -c "sleep 30; systemctl reboot" < /dev/null > /dev/null 2>&1 &
	;;
esac
