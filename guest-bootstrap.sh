#!/bin/sh
#
# anita が入れたばかりの NetBSD を、外から ssh で叩ける状態にする。
# イメージを作るときに一度だけ、anita の --run から実行される。
# ここでやったことはイメージに焼かれ、以後の起動はこの状態から始まる。
#
# 用途を限定しない。特定の CI 向けの細工は入れず、素の NetBSD に
# 「ネットワークが上がり、sshd が動き、ホストから渡された鍵で root に
# 入れる」だけを足す。

set -eu

echo "=== bootstrap 開始"

# pkgsrc の distfile は今どき大半が https なので、base の信頼アンカーを
# 使える形に展開しておく。古い版には certctl が無いので、あれば実行する。
if command -v certctl > /dev/null 2>&1; then
	certctl rehash || echo "certctl rehash に失敗 (無視して続行)"
fi

# 起動のたびにホストから ssh 公開鍵を取ってくる rc.d スクリプト。
#
# 鍵をイメージに焼かない理由は二つある。焼くと、公開されたイメージを見た
# 人にどの鍵が root を通せるか分かってしまう。そして使う側は対応する秘密鍵
# を用意しなければならず、CI では secret に置くことになる。取りに行く形なら
# 使う側が実行のたびに使い捨ての鍵対を作れて、secret が要らない。
#
# 10.0.2.2 は qemu の user networking から見たホスト。8123 は焼き込みなので
# 使う側もこの番号で配ること。
cat > /etc/rc.d/seed_key <<'EOF'
#!/bin/sh
#
# PROVIDE: seed_key
# REQUIRE: NETWORKING
# BEFORE: sshd

$_rc_subr_loaded . /etc/rc.subr

name="seed_key"
start_cmd="seed_key_start"
stop_cmd=":"

seed_key_start()
{
	mkdir -p /root/.ssh
	chmod 700 /root/.ssh

	i=0
	while [ $i -lt 90 ]; do
		if ftp -o /root/.ssh/authorized_keys \
		    http://10.0.2.2:8123/authorized_keys; then
			chmod 600 /root/.ssh/authorized_keys
			echo "seed_key: authorized_keys を置いた"
			return 0
		fi
		sleep 2
		i=$((i + 1))
	done
	echo "seed_key: ホストから鍵を取れなかった" >&2
	return 1
}

load_rc_config $name
run_rc_command "$1"
EOF
chmod 755 /etc/rc.d/seed_key

cat >> /etc/rc.conf <<'EOF'

# イメージの仕込み
dhcpcd=YES
dhclient=YES
sshd=YES
seed_key=YES
no_swap=YES
EOF

# 鍵でだけ root を通す。この VM は動かす側の 127.0.0.1 にしか出ていない。
cat >> /etc/ssh/sshd_config <<'EOF'

# イメージの仕込み
PermitRootLogin prohibit-password
PasswordAuthentication no
UseDNS no
EOF

# コンソールをシリアルにも出しておく。起動しなくなったときに、画面を撮る
# のではなくログで追えるようにするため。
if [ -f /etc/ttys ]; then
	sed -e 's|^\(tty00\)[[:space:]].*|\1	"/usr/libexec/getty std.9600"	vt100	on secure|' \
		/etc/ttys > /etc/ttys.new && mv /etc/ttys.new /etc/ttys
fi

mkdir -p /usr/pkgsrc

sync
echo "=== bootstrap 完了"
