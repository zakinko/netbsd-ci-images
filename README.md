# netbsd-ci-images

CI から起動するための、素の NetBSD ディスクイメージ置き場。

公式に配布されているのはインストーラ (ISO と `install.img`) が主で、インス
トール済みの live イメージは amd64 の 10.0 以降しかありません。i386 には一つ
も無く、9.x 以前にもありません。他の port には尚更ありません。CI で毎回インス
トールを走らせるのも現実的ではないので、ここで一度作って release に置いてい
ます。

作るのには [anita](https://www.gson.org/netbsd/anita/) を使います。NetBSD 本家
のテストでも使われている道具で、emulator の中で sysinst をシリアルコンソール
越しに操ってインストールします。**出来たイメージがその仮想ハードウェアで動く
ことが、作った時点で分かる**のが利点です。外から配布セットを展開してディスクを
組み立てる方法も試しましたが、その版のカーネルが虚仮にされた周辺機器を扱える
かは運任せで、NetBSD 5 は IDE で `piixide0: lost interrupt` を繰り返して起動
しませんでした。

## 何を作るか

[netbsd.org/ports](https://www.netbsd.org/ports/) にある port のうち、Ubuntu の
上で動かせるものと、1.0 から 11.0 までの全ての版の掛け算です。組み合わせは
`gen-targets.sh` がミラーを読んで数え上げ、`build-images` workflow が
まだ出来ていないものから順に埋めます。

動かせるかどうかは二つの条件の掛け算で、片方でも欠けると入りません。

1. その機械を真似られる emulator が Ubuntu にあること
2. anita がその port の入れ方を知っていること

いま揃っているのは `ports.conf` にある 14 種です。

| port | emulator | 備考 |
| --- | --- | --- |
| i386 amd64 | QEMU | runner が x86_64 なので KVM が効く。実速 |
| sparc sparc64 | QEMU | |
| alpha | QEMU | SRM が無いので毎回カーネルを外から渡す |
| hppa | QEMU | 6.0 より前は `hp700` という名前だった |
| macppc | QEMU | FFS から起動できないので毎回 CD から起こす |
| evbarm evbarm64 riscv64 | QEMU | 展開済みイメージから起こす。release には無く daily のみ |
| pmax hpcmips landisk | gxemul | ホストから ssh で入る口が作れない |
| vax | simh | 同上 |

mac68k (q800)、virt68k、evbmips (malta)、prep (40p)、arc、zaurus のように
**QEMU に機械はあるが anita が入れ方を知らない** port は、まだ入りません。
入れる手順を別に書き起こす必要があります。amiga、atari、x68k、sun3、sgimips、
next68k のように QEMU 側に機械が無いものは、そもそも動かせません。

版のほうにも下限があります。sysinst そのものが 1.3 からなので、1.2.1 以前は
anita では入りません。

## 中身

特定の用途に寄せた細工はしていません。配布セットを展開して、`sshd` を上げ、
`root` の `authorized_keys` を置いただけです。何を組むのにも使えます。

- その版に在るセットを全部入れてあります。`xbase` `xserver` などが在れば
  X も入るので、`Xvfb` を使う検査にもそのまま使えます。何が在るかは版で
  違う (`modules` は 5.0 から、`xetc` は 2.0 から、1.4 以前の kernel セット
  は `kern-GENERIC` ではなく `kern`) ので、`binary/sets/` を見て決めています
- swap は切ってあります (`no_swap=YES`)
- 大きさは版に合わせて 2〜12 GiB の sparse イメージです

## 繋ぎ方

イメージと emulator の繋ぎ方が食い違うと root が見つからず起動しません。組み
合わせは各イメージに添えた `<port>-<release>.qemu` に書いてあります。

```
PORT=macppc
RELEASE=9.4
VMM=qemu
QEMU=qemu-system-ppc
DISKARGS="-drive file=@IMG@,format=qcow2,media=disk"
EXTRAARGS="-M mac99 -prom-env qemu_boot_hack=y -prom-env boot-device=cd:,netbsd-GENERIC -drive file=@BOOTISO@,..."
ROOTDEV=wd0a
SSH=yes
SSHOPTS="..."
```

`@IMG@` `@KERNEL@` `@BOOTISO@` `@DTB@` `@MEM@` をそれぞれのファイルに置き換え
て使ってください。`runvm.sh` がこの置き換えをやります。

イメージだけでは起動しない port があります。

- **alpha** QEMU に SRM が無いので、毎回 `-kernel` でカーネルを渡します
- **macppc** FFS から起動できないので、`ofwboot` と `netbsd-GENERIC` の入った
  CD から起こし、root だけディスクを使います。起動のたびにカーネルが
  `root device:` と聞いてくるので、`console.py` がシリアル越しに答えます
- **evbarm evbarm64 riscv64** ブートローダを通らないので `-kernel`。
  evbarm はさらに device tree (`.dtb`) も要ります

要るものは `.kernel` `.bootiso` `.dtb` としてイメージと一緒に release に
置いてあります。

```sh
sh runvm.sh i386-10.1 2222
$(cat i386-10.1.ssh) uname -a
sh stopvm.sh i386-10.1
```

gxemul と simh の port は `runvm.sh` では起動しません。どちらにも user
networking も port forward も無く、ホストから ssh で入る口がそもそも作れない
ためです。組んだ時点で anita が login まで出したことは確かめてあるので、
あとはコンソールで使うことになります。動かし方は `runvm.sh` が表示します。

## 組み方

```sh
pip install pexpect https://www.gson.org/netbsd/anita/download/anita-2.18.tar.gz
sudo apt-get install qemu-system-x86 qemu-system-sparc qemu-system-ppc \
    qemu-system-arm qemu-system-misc qemu-utils genisoimage gxemul simh
sh build-image.sh i386 10.1
sh build-image.sh riscv64 netbsd-11    # daily からしか組めない port
```

NetBSD のコマンドは要らないので Linux でも macOS でも動きます。普段は GitHub
Actions の `build-images` workflow から回します。runner は x86_64 の Linux で
KVM が使えるので、i386 と amd64 のゲストはほぼ実速で動きます。他の port は
emulation で、install だけで数時間かかります。

一度で全部は終わりません。組み合わせは千に近いので、workflow は一回あたり
`limit` 個 (既定 40) だけを組み、出来たものから release に積みます。掛け直せば
続きから進みます。転けたものは次も候補に残るので、直せば拾い直せます。

`anita` は配布ツリーの URL の最後の要素をそのまま port 名として読みます。
release ツリーでの名前が anita の期待と食い違う場合 (`hp700`、daily にしか
無い `evbarm-earmv7hf`) があるので、302 を返すだけの中継 (`mirror-alias.py`)
を手元に立てて名前を揃えています。ゲストに配るものも同じポートから出します。

`mkimg.sh` も残してあります。配布セットを直接展開する古い方法で、**NetBSD の
上でしか動きません**。anita が扱わない port が出てきたときの逃げ道です。

## 鍵

**イメージに鍵は焼かれていません。** ゲストは起動のたびに
`http://10.0.2.2:8123/authorized_keys` を取りに行きます (`/etc/rc.d/seed_key`、
1.4 以前は `/etc/rc.local`)。`runvm.sh` が使い捨ての鍵対をその場で作り、この
URL で配ります。

焼かない理由は二つあります。焼くと、公開されたイメージを見た人にどの鍵が root
を通せるか分かります。そして使う側は対応する秘密鍵を用意することになり、CI では
secret に置く羽目になります。取りに行く形なら **secret も固定の鍵も要りません**。

ポート 8123 はゲストの `rc.d` に焼き込んであるので変えられません。同じ機械で
二つ動かすと取り合いになります。

### 古い版の ssh

base の `sshd` は版によって喋れるものが違い、古いほど今の OpenSSH と噛み合い
ません。

| 版 | base の ssh | 入り方 |
| --- | --- | --- |
| 6.0 以降 | OpenSSH 5.x 以降 | そのまま |
| 2.0 〜 5.x | OpenSSH 3.6 以降 | `ssh-rsa`、group1 の kex、cbc、hmac-md5 を名指しで許す |
| 1.6.x | OpenSSH 3.4 | 同上 |
| 1.5.x | OpenSSH 2.x | SSH2 は DSA のみ。OpenSSH を組んで差し替える |
| 1.4 以前 | 無い | 同上 |

1.5.x 以前はイメージを作るときに OpenSSH 3.9p1 を組んで `sshd` を差し替えます。
pkgsrc でやりたいところですが、その版に釣り合う古い pkgsrc の木も当時の
distfile も今では揃わないので、やることは同じまま配布物から直接組んでいます。
tarball はホスト側が取ってきて 8123 から配ります (当時の `ftp` に TLS は無く、
ゲストから https を引けないため)。

組めなかったときは base の `sshd` のまま残ります。1.5.x なら DSA でなら入れる
余地があるので、`runvm.sh` は RSA と DSA の両方を配って両方を提示します。ただ
しホスト側の OpenSSH が 10.0 以降だと DSA そのものが無いので、その場合は入れま
せん。workflow が runner を `ubuntu-24.04` に固定しているのはこのためです
(OpenSSH 9.6 はまだ DSA を作れます)。

## 中身の出どころ

展開しているのは NetBSD の配布セットそのままで、こちらでの改変はありません。
NetBSD は BSD licence です。
