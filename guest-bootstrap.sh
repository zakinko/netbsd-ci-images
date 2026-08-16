#!/bin/sh
#
# anita が入れたばかりの NetBSD を、外から ssh で叩ける状態にする。
# イメージを作るときに一度だけ、anita の --run から実行される。
# ここでやったことはイメージに焼かれ、以後の起動はこの状態から始まる。
#
# 用途を限定しない。特定の CI 向けの細工は入れず、素の NetBSD に
# 「ネットワークが上がり、sshd が動き、ホストから渡された鍵で root に
# 入れる」だけを足す。
#
# 1.0 から 11.0 までが通る。この幅では前提がほとんど何も揃わないので、
# 在るものを見てから使う。rc.d は 1.5 から、certctl は 10 から、
# base の ssh は 1.5 から、その ssh が SSH2 で RSA を喋るのは 1.6 から。
#
# 呼ぶ側から渡るもの:
#   REL       版 (1.6.2 など)。何が在るかの見当をつけるのに使う
#   SSH_MODE  base   = base の sshd をそのまま使う
#             build  = OpenSSH を組んで差し替える (1.5.x 以前)

set -u

REL=${REL:-}
SSH_MODE=${SSH_MODE:-base}
SEED=http://10.0.2.2:8123

echo "=== bootstrap 開始 (REL=$REL SSH_MODE=$SSH_MODE)"

# command -v は古い /bin/sh に無いことがある。type はある。
have() {
	type "$1" > /dev/null 2>&1
}

# pkgsrc の distfile は今どき大半が https なので、base の信頼アンカーを
# 使える形に展開しておく。古い版には certctl が無いので、あれば実行する。
if have certctl; then
	certctl rehash || echo "certctl rehash に失敗 (無視して続行)"
fi

# ------------------------------------------------------------------
# 起動のたびにホストから ssh 公開鍵を取ってくる仕掛け。
#
# 鍵をイメージに焼かない理由は二つある。焼くと、公開されたイメージを見た
# 人にどの鍵が root を通せるか分かってしまう。そして使う側は対応する秘密鍵
# を用意しなければならず、CI では secret に置くことになる。取りに行く形なら
# 使う側が実行のたびに使い捨ての鍵対を作れて、secret が要らない。
#
# 10.0.2.2 は qemu の user networking から見たホスト。8123 は焼き込みなので
# 使う側もこの番号で配ること。
#
# rc.d は 1.5 から。それ以前は rc.local に直に書く。
# 本体は rc.d でも rc.local でも同じなので、一度だけ書いて挟み込む。
# 変数を含むので、ここで展開されないよう引用した heredoc で置く。
cat > /tmp/seed_body.sh <<'BODY'
	mkdir -p /root/.ssh
	chmod 700 /root/.ssh
	i=0
	while [ $i -lt 90 ]; do
		if ftp -o /root/.ssh/authorized_keys \
		    http://10.0.2.2:8123/authorized_keys; then
			chmod 600 /root/.ssh/authorized_keys
			echo "seed_key: authorized_keys を置いた"
			break
		fi
		sleep 2
		i=$((i + 1))
	done
BODY

if [ -d /etc/rc.d ] && [ -f /etc/rc.subr ]; then
	{
		cat <<'HEAD'
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
HEAD
		cat /tmp/seed_body.sh
		cat <<'TAIL'
	return 0
}

load_rc_config $name
run_rc_command "$1"
TAIL
	} > /etc/rc.d/seed_key
	chmod 755 /etc/rc.d/seed_key
	RCD=yes
else
	# 1.4 以前。rc.local は rc の最後、ネットワークが上がった後に走る。
	{
		cat <<'HEAD'

# イメージの仕込み。起動のたびにホストから公開鍵を取る。
seed_key() {
HEAD
		cat /tmp/seed_body.sh
		echo '}'
		echo 'seed_key'
	} >> /etc/rc.local
	RCD=no
fi

# ------------------------------------------------------------------
# hostname を空のままにすると postfix が "unable to use my own hostname" で
# 起動に失敗し、rc が毎回それを報告する。害は無いが、本当の失敗を探すときに
# 邪魔なので埋めておく。
#
# dhcpcd は 4.0 から、dhclient はそれ以前から。知らない変数は無視されるので
# 両方書いておけばどの版でも当たる。
cat >> /etc/rc.conf <<'EOF'

# イメージの仕込み
hostname=nbimg
dhcpcd=YES
dhclient=YES
sshd=YES
seed_key=YES
no_swap=YES
EOF

# ------------------------------------------------------------------
# sshd の設定。置き場所が版で違うので探す。
#
# 綴りは without-password のほう。prohibit-password は OpenSSH 6.7 からで、
# NetBSD 7 以前の sshd は解さず、設定を読んだ時点で起動に失敗する。古い綴り
# は今の OpenSSH でも別名として通るので、どの版でもこれで済む。
#
# UseDNS は書かない。OpenSSH 3.7 より前は知らない語で止まる。
sshd_config_path() {
	for f in /etc/ssh/sshd_config /etc/sshd.conf /etc/ssh/sshd.conf; do
		[ -f "$f" ] && { echo "$f"; return 0; }
	done
	return 1
}

if CONF=$(sshd_config_path); then
	cat >> "$CONF" <<'EOF'

# イメージの仕込み
PermitRootLogin without-password
PasswordAuthentication no
EOF
	echo "sshd の設定は $CONF"
else
	echo "base に sshd が無い"
fi

# 鍵が無ければ作る。1.x の sshd は自分では作らない。
if have ssh-keygen; then
	[ -f /etc/ssh/ssh_host_key ] ||
		ssh-keygen -t rsa1 -f /etc/ssh/ssh_host_key -N '' > /dev/null 2>&1 ||
		ssh-keygen -f /etc/ssh/ssh_host_key -N '' > /dev/null 2>&1 || true
	[ -f /etc/ssh/ssh_host_rsa_key ] ||
		ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N '' > /dev/null 2>&1 || true
	[ -f /etc/ssh/ssh_host_dsa_key ] ||
		ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key -N '' > /dev/null 2>&1 || true
fi

# ------------------------------------------------------------------
# 1.5.x 以前は base の ssh では今のホストから入れない。
#
#   1.5.x    OpenSSH 2.x。SSH2 は DSA だけ。今の OpenSSH は 10.0 で DSA を
#            落としたので、ホストが新しいと鍵の種類が一つも噛み合わない
#   1.4 以前 ssh そのものが無い
#
# そこで OpenSSH を組んで差し替える。pkgsrc でやりたいところだが、その版に
# 釣り合う古い pkgsrc の木も、当時の distfile も今では揃わない。やることは
# pkgsrc と同じなので、配布物から直接組む。tarball はホストが 8123 で配る。
#
# 3.9p1 を選んだのは、gcc 2.95 と OpenSSL 0.9.x で通る最後の世代のうち、
# SSH2 の ssh-rsa を喋るものだから。特権分離は使わない (sshd 用の使わない
# ユーザを作らずに済ませるため)。
build_openssh() {
	cd /tmp || return 1
	ftp -o /tmp/openssh.tar.gz "$SEED/openssh.tar.gz" || return 1

	# OpenSSL は 1.5 の base には入っているが 1.4 以前には無い。
	SSLARG=
	if [ ! -f /usr/include/openssl/rsa.h ]; then
		echo "--- OpenSSL から組む"
		ftp -o /tmp/openssl.tar.gz "$SEED/openssl.tar.gz" || return 1
		gunzip -c /tmp/openssl.tar.gz | tar xf - || return 1
		cd /tmp/openssl-* || return 1
		./config --prefix=/usr/local no-shared no-asm > /tmp/ssl.log 2>&1 ||
			{ tail -20 /tmp/ssl.log; return 1; }
		make >> /tmp/ssl.log 2>&1 || { tail -20 /tmp/ssl.log; return 1; }
		make install >> /tmp/ssl.log 2>&1 || { tail -20 /tmp/ssl.log; return 1; }
		SSLARG=--with-ssl-dir=/usr/local
		cd /tmp || return 1
	fi

	gunzip -c /tmp/openssh.tar.gz | tar xf - || return 1
	cd /tmp/openssh-* || return 1
	./configure --prefix=/usr/local --sysconfdir=/etc/ssh \
		--with-privsep-path=/var/empty $SSLARG > /tmp/ssh.log 2>&1 ||
		{ tail -30 /tmp/ssh.log; return 1; }
	make >> /tmp/ssh.log 2>&1 || { tail -30 /tmp/ssh.log; return 1; }
	make install >> /tmp/ssh.log 2>&1 || { tail -30 /tmp/ssh.log; return 1; }

	mkdir -p /etc/ssh /var/empty
	cat >> /etc/ssh/sshd_config <<'EOF'

# イメージの仕込み
PermitRootLogin without-password
PasswordAuthentication no
UsePrivilegeSeparation no
EOF
	/usr/local/bin/ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N '' > /dev/null 2>&1 || true
	/usr/local/bin/ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key -N '' > /dev/null 2>&1 || true
	return 0
}

if [ "$SSH_MODE" = build ]; then
	echo "=== OpenSSH を組む"
	if build_openssh; then
		echo "=== OpenSSH を組んで入れた"
		# base の sshd とは番号を取り合うので、あちらは止める。
		sed -e 's/^sshd=YES/sshd=NO/' /etc/rc.conf > /etc/rc.conf.new &&
			mv /etc/rc.conf.new /etc/rc.conf
		if [ "$RCD" = yes ]; then
			cat > /etc/rc.d/sshd_local <<'EOF'
#!/bin/sh
#
# PROVIDE: sshd_local
# REQUIRE: seed_key NETWORKING

$_rc_subr_loaded . /etc/rc.subr

name="sshd_local"
command="/usr/local/sbin/sshd"
start_cmd="$command"
stop_cmd=":"

load_rc_config $name
run_rc_command "$1"
EOF
			chmod 755 /etc/rc.d/sshd_local
			echo 'sshd_local=YES' >> /etc/rc.conf
		else
			echo '/usr/local/sbin/sshd' >> /etc/rc.local
		fi
	else
		# 組めなくても base の sshd は残っている。1.5.x なら DSA でなら
		# 入れる余地があるので、ここで止めずに続ける。どちらになったかは
		# ログに残る。
		echo "!! OpenSSH を組めなかった。base の sshd のままにする"
	fi
fi

# ------------------------------------------------------------------
# コンソールをシリアルにも出しておく。起動しなくなったときに、画面を撮る
# のではなくログで追えるようにするため。
if [ -f /etc/ttys ]; then
	sed -e 's|^\(tty00\)[[:space:]].*|\1	"/usr/libexec/getty std.9600"	vt100	on secure|' \
		/etc/ttys > /etc/ttys.new && mv /etc/ttys.new /etc/ttys
fi

mkdir -p /usr/pkgsrc

sync
echo "=== bootstrap 完了"
