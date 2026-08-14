# netbsd-ci-images

CI から QEMU で起動するための、素の NetBSD ディスクイメージ置き場。

公式に配布されているのはインストーラ (ISO と `install.img`) が主で、インス
トール済みの live イメージは amd64 の 10.0 以降しかありません。i386 には一つ
も無く、9.x 以前にもありません。CI で毎回インストールを走らせるのも現実的では
ないので、ここで一度作って release に置いています。

作るのには [anita](https://www.gson.org/netbsd/anita/) を使います。NetBSD 本家
のテストでも使われている道具で、QEMU の中で sysinst をシリアルコンソール越しに
操ってインストールします。**出来たイメージがその仮想ハードウェアで動くことが、
作った時点で分かる**のが利点です。外から配布セットを展開してディスクを組み立て
る方法も試しましたが、その版のカーネルが虚仮にされた周辺機器を扱えるかは運任せ
で、NetBSD 5 は IDE で `piixide0: lost interrupt` を繰り返して起動しませんでした。

## 中身

特定の用途に寄せた細工はしていません。配布セットを展開して、`sshd` を上げ、
`root` の `authorized_keys` を置いただけです。何を組むのにも使えます。

- `base` `etc` `comp` `text` に加え、あれば `xbase` `xcomp` `xetc` `xfont`
  `xserver` を展開してあります。`Xvfb` はここに入るので、X を使うものを
  試すのにそのまま使えます
- swap は切ってあります (`no_swap=YES`)
- 12 GiB の sparse イメージです。展開後の実サイズはずっと小さくなります

## 繋ぎ方

イメージと QEMU の繋ぎ方が食い違うと root が見つからず起動しません。組み合
わせは各イメージに添えた `<arch>-<release>.qemu` に書いてあります。

```
ARCH=i386
RELEASE=10.1
QEMU=qemu-system-i386
DISKIF=virtio-scsi
DISKARGS="-device virtio-scsi-pci,id=scsi0 -drive file=@IMG@,if=none,id=d0,format=raw -device scsi-hd,drive=d0,bus=scsi0.0"
NICDEV=virtio-net-pci
ROOTDEV=sd0a
```

ディスクは版によって三通りに分かれます。

| 版 | 繋ぎ方 | root |
| --- | --- | --- |
| 10 以降 | virtio-scsi (`vioscsi`) | `sd0a` |
| 6.0 〜 9.x | virtio-blk | `ld0a` |
| 5.x 以下 | IDE | `wd0a` |

`virtio` そのものが NetBSD 6.0 から、`vioscsi` は 10 からです。NIC も同じ理由
で 5.x 以下は `ne2k_pci` になります。切り替えはイメージを組む時点で行われ、
`/etc/fstab` もそれに合わせて書かれています。

virtio-scsi は `-drive if=...` では繋がらず、コントローラと `scsi-hd` を別々
に並べる必要があります。そのため `.qemu` にはインタフェース名ではなくディスク
指定の全体を `DISKARGS` として持たせてあります。`@IMG@` をイメージのパスに
置き換えて使ってください。

```sh
. ./i386-10.1.qemu
DISK=`echo "$DISKARGS" | sed "s|@IMG@|i386-10.1.img|g"`
$QEMU -m 2048 -smp 2 $DISK \
      -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 \
      -device $NICDEV,netdev=n0 \
      -display none -daemonize
ssh -p 2222 root@127.0.0.1
```

`runvm.sh` がこの置き換えをやります。

## 組み方

`build-image.sh` を走らせます。NetBSD のコマンドは要らないので Linux でも
macOS でも動きます。必要なのは QEMU、`genisoimage` (macOS なら `mkisofs`)、
それに anita です。

```sh
pip install pexpect https://www.gson.org/netbsd/anita/download/anita-2.18.tar.gz
sh build-image.sh i386 10.1
```

普段は GitHub Actions の `build-images` workflow から回します。runner は
x86_64 の Linux で KVM が使えるので、i386 と amd64 のゲストはほぼ実速で動き
ます。手元の arm64 機では emulation になり、install だけで 1〜2 時間かかります。

`mkimg.sh` も残してあります。配布セットを直接展開する古い方法で、**NetBSD の
上でしか動きません**。anita が扱わない port が出てきたときの逃げ道です。

9.0 より前のリリースは本ミラーから外れているので、`archive.netbsd.org` を
見に行きます。FFSv2 は NetBSD 2.0 からなので、それ以前は FFSv1 で作ります。
ブートローダの置き方はアーキテクチャで違い、i386/amd64 は MBR を掘ってその
中に disklabel を置き、sparc64 は MBR を使わず `bootblk` をパーティションの
セクタ 1 に入れます。

`installboot` は生デバイスに書くので、マウントしたままだとカーネルに拒まれ
ます。必要なファイルを取り出してから `umount` して書いています。

## 鍵

**イメージに鍵は焼かれていません。** ゲストは起動のたびに
`http://10.0.2.2:8123/authorized_keys` を取りに行きます (`/etc/rc.d/seed_key`)。
`runvm.sh` が使い捨ての鍵対をその場で作り、この URL で配ります。

焼かない理由は二つあります。焼くと、公開されたイメージを見た人にどの鍵が root
を通せるか分かります。そして使う側は対応する秘密鍵を用意することになり、CI では
secret に置く羽目になります。取りに行く形なら **secret も固定の鍵も要りません**。

ポート 8123 はゲストの `rc.d` に焼き込んであるので変えられません。同じ機械で
二つ動かすと取り合いになります。

## 中身の出どころ

展開しているのは NetBSD の配布セットそのままで、こちらでの改変はありません。
NetBSD は BSD licence です。
