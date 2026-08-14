# netbsd-ci-images

CI から QEMU で起動するための、素の NetBSD ディスクイメージ置き場。

公式に配布されているのはインストーラ (ISO と `install.img`) だけで、インス
トール済みのイメージはありません。sysinst に無人インストールの仕組みも無い
ので、CI で毎回インストールを走らせるのは現実的ではありません。ここでは配布
セットを直接展開してブート可能なイメージを組み、release に置いています。

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

`mkimg.sh` を **NetBSD の上で** root で走らせます。`vnconfig` `disklabel`
`newfs` `installboot` が要るので、Linux では組めません。

```sh
sh mkimg.sh i386 10.1
sh mkimg.sh sparc64 11.0
```

9.0 より前のリリースは本ミラーから外れているので、`archive.netbsd.org` を
見に行きます。FFSv2 は NetBSD 2.0 からなので、それ以前は FFSv1 で作ります。
ブートローダの置き方はアーキテクチャで違い、i386/amd64 は MBR を掘ってその
中に disklabel を置き、sparc64 は MBR を使わず `bootblk` をパーティションの
セクタ 1 に入れます。

`installboot` は生デバイスに書くので、マウントしたままだとカーネルに拒まれ
ます。必要なファイルを取り出してから `umount` して書いています。

## 鍵

`authorized_keys` は各自のものを使ってください。`$BASE/authorized_keys` に
置いておくと、それがイメージに入ります。

## 中身の出どころ

展開しているのは NetBSD の配布セットそのままで、こちらでの改変はありません。
NetBSD は BSD licence です。
