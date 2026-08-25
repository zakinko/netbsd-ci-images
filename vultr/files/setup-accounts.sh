#!/bin/sh
# ホスト名を決め、その名前の下にアカウントのホームを掘る。
#
#   sh setup-accounts.sh <hostname> <user>:<uid>:<wheel> ...
#
# 焼いたイメージではなくここでやるのは、名前が外から与えられるものだから。
# Vultr は instance に hostname を持たせられるが、それを guest へ渡すのは
# cloud-init の役目で、生イメージの NetBSD には届かない。guest が自力で
# 知れるのは逆引きの ...vultrusers.net くらいで、欲しい名前にはならない。
#
# 冪等。二度目からは既にあるものに触らない。
set -e

PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PATH

HOST=$1
shift
[ -n "$HOST" ] || { echo "$0: ホスト名が要る" >&2; exit 1; }

# 走らせるたびに名前が変わると困るので rc.conf にも書く。次の起動でも残る。
hostname "$HOST"
if grep -q '^hostname=' /etc/rc.conf; then
	sed -e "s|^hostname=.*|hostname=$HOST|" /etc/rc.conf > /etc/rc.conf.new
	mv /etc/rc.conf.new /etc/rc.conf
else
	echo "hostname=$HOST" >> /etc/rc.conf
fi

BASE=/usr/home/$HOST
mkdir -p "$BASE"

# bambi と同じ番号にしておく。同じ人が同じ番号で居ると、NFS でも tar でも
# 持ち回りが楽になる。
grep -q '^nsrg:' /etc/group || groupadd -g 2008 nsrg

for spec in "$@"; do
	name=${spec%%:*}
	rest=${spec#*:}
	uid=${rest%%:*}
	wheel=${rest##*:}

	if grep -q "^$name:" /etc/master.passwd; then
		echo "    $name は既に居る"
	else
		# shell は /bin/csh。bambi の /usr/pkg/bin/tcsh は pkgsrc の
		# もので、このイメージには入っていない。指しても入れない。
		useradd -u "$uid" -g nsrg -d "$BASE/$name" -s /bin/csh -m "$name"
		echo "    $name (uid $uid) を作った"
	fi

	if [ "$wheel" = yes ]; then
		usermod -G wheel "$name"
	fi

	install -d -o "$name" -g nsrg -m 700 "$BASE/$name/.ssh"
done

echo "ホスト名: $(hostname)"
ls -ld "$BASE"/*
