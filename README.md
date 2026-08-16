# netbsd-ci-images

CI から起動するための、素の OS ディスクイメージ置き場。
English: [README.en.md](README.en.md) / 対応状況: [SUPPORT.md](SUPPORT.md)

NetBSD が中心ですが、emulator の上で動いて ssh で入れるものは何でも扱います。

公式に配布されているのはインストーラ (ISO と `install.img`) が主で、インス
トール済みの live イメージは限られています。NetBSD なら amd64 の 10.0 以降
だけ、i386 には一つも無く、9.x 以前にもありません。他の port には尚更あり
ません。CI で毎回インストールを走らせるのも現実的ではないので、ここで一度
作って release に置いています。

## 中身

特定の用途に寄せた細工はしていません。配布物を展開して `sshd` を上げ、
`root` の `authorized_keys` を置いただけです。何を組むのにも使えます。

- NetBSD はその版に在るセットを全部入れてあります (`xbase` `xserver` などが
  在れば X も)。`Xvfb` を使う検査にもそのまま使えます
- swap は切ってあります
- **鍵は焼かれていません**。起動のたびにホストから取りに来ます (後述)

## 起動のしかた

繋ぎ方はイメージに添えた `<名前>.qemu` に書いてあります。イメージと食い違う
と root が見つからず起動しないので、決め打ちにせずそれを読んでください。

### NetBSD

```sh
sh runvm.sh i386-10.1 2222      # 起こして ssh が上がるまで待つ
$(cat i386-10.1.ssh) uname -a   # 入り方も runvm.sh が書き出す
sh stopvm.sh i386-10.1          # 正規手順で止める (電源断は FFS を壊す)
```

port によっては、イメージのほかにホストから渡すものが要ります。いずれも
`.kernel` `.bootiso` `.dtb` として release に置いてあります。

| port | 要るもの | なぜ |
| --- | --- | --- |
| alpha | `.kernel` | QEMU の alpha に SRM が無い |
| macppc | `.bootiso` | FFS から起動できないので CD から起こす。起動のたびに `root device:` と聞かれるので `console.py` が答える |
| evbarm | `.kernel` `.dtb` | ブートローダを通らない |
| evbarm64 riscv64 | `.kernel` | 同上 |
| pmax hpcmips landisk | `.kernel` | gxemul に渡す |

**gxemul と simh の port (pmax hpcmips landisk vax) は ssh で入れません。**
どちらにも user networking も port forward も無く、ホストから繋ぐ口が作れ
ないためです。起動することは組んだ時点で確かめてあります。動かし方は
`runvm.sh` が表示します。

### FreeBSD

```sh
sh build.sh freebsd-14.3-amd64   # 取得・起動・ssh の仕込みまで
$(cat out/freebsd-14.3-amd64.ssh) uname -a
```

公式の VM イメージをそのまま使いますが、**そのままでは何も見えません**。
癖が三つあります。

1. **VGA が在ると firmware も loader も画面側にしか出しません。** `-serial`
   に socket を宛てても一文字も来ず、`-vga none` にしても変わりません。
   `-nographic` のときだけシリアルに出ます
2. **カーネルのコンソールは Video 固定**で出荷されています。loader のメニュー
   で `5` を押すと `Cons: Dual (Serial primary)` になり、続けて `1` を押すと
   multi user で起動します。**Enter は効きません** (loader は CR を待って
   おり LF では動かない) ので番号を押します
3. **host key がありません。** `sshd_enable=YES` だけでは
   `No host key files found` で起動に失敗するので `ssh-keygen -A` が要ります

### SunOS 4.1.4 (sparc)

```sh
sh build.sh sunos-4.1.4-sparc
```

QEMU の SS-5 で動きます。**専有 PROM は要りません** (QEMU 同梱の OpenBIOS で
起動します)。癖は三つ。

- root にパスワードはありません。**root の shell は csh** なので `2>&1` は
  通りません。込み入ったことは `sh -c` で包みます
- **IP が固定で焼かれていて** qemu の user networking と噛み合いません。
  SunOS 4 に DHCP は無いので `ifconfig le0 10.0.2.15` と
  `route add default 10.0.2.2` で振り直します
- gcc が無く `/bin/cc` は K&R です。**ssh はまだ通せていません**
  ([SUPPORT.md](SUPPORT.md))

## 組み方

```sh
pip install pexpect https://www.gson.org/netbsd/anita/download/anita-2.18.tar.gz
sudo apt-get install qemu-system-x86 qemu-system-sparc qemu-system-ppc \
    qemu-system-arm qemu-system-misc qemu-utils genisoimage gxemul simh

sh build-image.sh i386 10.1        # NetBSD (anita が sysinst を操る)
sh build-image.sh riscv64 netbsd-11
sh build.sh freebsd-14.3-amd64     # それ以外
```

`build.sh` は `targets/<名前>.conf` を読みます。入れ方は `DRIVER` で分かれ
ます。

| DRIVER | 入れ方 |
| --- | --- |
| `prebuilt` | 展開済みイメージを起こすだけ |
| `anita` | sysinst を操る (NetBSD) |
| `autoinstall` | 応答ファイルを置く (OpenBSD) |
| `expect` | インストーラをコンソールで操る (これから) |
| `builder-vm` | NetBSD ゲストの中で生ディスクを組む (これから) |

レシピの肝は `STEPS` で、「待つもの => 打つもの」を並べたものです。手で
コンソールに打って通った手順を、そのまま書き写せます。流すのは `talk.py`
です。

```
STEPS="login:=>root|#=>ifconfig le0 10.0.2.15 netmask 255.255.255.0 up"
```

NetBSD の総当たりは GitHub Actions の `build-images` workflow から回します。
port と版の掛け算は 719 通りあるので、一度に全部は終わりません。まだ出来て
いないものから `limit` 個ずつ組み、掛け直せば続きから進みます。

`anita` は配布ツリーの URL の最後の要素をそのまま port 名として読みます。
release ツリーでの名前が anita の期待と食い違う場合 (`hp700`、daily にしか
無い `evbarm-earmv7hf`) があるので、302 を返すだけの中継 (`mirror-alias.py`)
を手元に立てて名前を揃えています。

## 新しい OS を足す

手順が書かれていないものばかりなので、決まった型で当たります。

1. **まず手で起こす。** `qemu-system-… -nographic` で観察する。ここで何も
   出ないなら、出し方の問題 (下の表) であってイメージの問題ではない
2. **コンソールの引き出し方を決める。** firmware がシリアルに出す機械
   (sparc、hppa) は `-serial unix:…` で足りる。x86 は `-nographic` でないと
   出ないので `CONSOLE=stdio`
3. **手でログインし、ネットワークを通す。** ここで OS ごとの癖が出る
   (shell が csh、IP が固定で焼かれている、DHCP が無い、など)
4. **鍵を置いて ssh を通す。** ベンダの sshd → 無ければ pkgsrc → それも
   駄目なら「作れない」側へ回す
5. **通った手順をそのまま `targets/<名前>.conf` の `STEPS` に書き写す。**
   手で打った順番と文字列がそのまま動く
6. `sh build.sh <名前>` で**同じ結果が再現するか**確かめる
7. 分かった癖を [SUPPORT.md](SUPPORT.md) に足す

手で観察するときは `talk.py` をそのまま使えます。

```sh
mkfifo in; (sleep 3000 > in &)
qemu-system-x86_64 -m 2048 -drive file=disk.qcow2,format=qcow2 -nographic < in > con.log 2>&1 &
python3 talk.py --outfile con.log --infile in --log con.log --kick --step 'login:=>root'
```

## 鍵

**イメージに鍵は焼かれていません。** ゲストは起動のたび、あるいは仕込みの
途中で一度だけ、ホストから公開鍵を取りに来ます。`runvm.sh` と `build.sh` が
使い捨ての鍵対をその場で作って配ります。

焼かない理由は二つあります。焼くと、公開されたイメージを見た人にどの鍵が
root を通せるか分かります。そして使う側は対応する秘密鍵を用意することに
なり、CI では secret に置く羽目になります。取りに行く形なら **secret も
固定の鍵も要りません**。

配る番号は実行のたびに空いているものを選びます。NetBSD のイメージだけは
`rc.d` に 8123 が焼き込んであるので変えられません。同じ機械で二つ動かすと
取り合いになります (実際、別のセッションが握っていて、ゲストが向こうの鍵を
取ってきてしまい入れなくなったことがあります)。

## 古い版の ssh

base の `sshd` は版によって喋れるものが違い、古いほど今の OpenSSH と噛み
合いません。NetBSD の場合:

| 版 | base の ssh | 入り方 |
| --- | --- | --- |
| 6.0 以降 | OpenSSH 5.x 以降 | そのまま |
| 2.0 〜 5.x | OpenSSH 3.6 以降 | `ssh-rsa`、group1 の kex、cbc、hmac-md5 を名指しで許す |
| 1.6.x | OpenSSH 3.4 | 同上 |
| 1.5.x | OpenSSH 2.x | SSH2 は DSA のみ。OpenSSH を組んで差し替える |
| 1.4 以前 | 無い | 同上 |

1.5.x 以前はイメージを作るときに OpenSSH 3.9p1 を組んで差し替えます。pkgsrc
でやりたいところですが、その版に釣り合う古い pkgsrc の木も当時の distfile も
今では揃わないので、やることは同じまま配布物から直接組んでいます。

workflow が runner を `ubuntu-24.04` に固定しているのは、ここの OpenSSH 9.6
がまだ DSA を作れるからです。新しい runner では 1.5.x の guest に入れません。

## 公開と手元

再配布の許諾があるものだけを release に置きます。手元の媒体から作った商用
Unix のイメージは、**release にも artifact にも上げません**。レシピの
`LICENSE` が `free` かどうかで切り替わり、CI は `free` のものだけを見ます。
詳しくは [SUPPORT.md](SUPPORT.md)。

## 中身の出どころ

NetBSD の配布セット、FreeBSD の VM イメージなど、配布物そのままで、こちら
での改変はありません。いずれも BSD licence です。
