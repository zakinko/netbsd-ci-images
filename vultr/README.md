# Vultr に NetBSD を書く

Vultr の VPS を NetBSD にする。中身は [`../mkimg.sh`](../mkimg.sh) が焼いた
生イメージそのままで、この repo が CI 用に作っているものと同じ作り方をした
ものを、QEMU ではなく本物のディスクに書いている。

## どうやって書いているか

Vultr の API に `POST /v2/snapshots/create-from-url` がある。公開 URL に置いた
**raw ディスクイメージ**を snapshot として取り込む口で、そこから instance を
deploy すると、そのイメージがディスクへそのまま書き戻される。**レスキューに
落ちて dd するのと同じことが API 二回で済む。** VNC も要らず、走っている
Linux の root を上書きするような曲芸も要らない。

Vultr は NetBSD を OS の一覧に持っていないので、入れる道はこれか custom ISO
から sysinst を叩くかの二つしかない。後者は対話が VNC 越しになる。

## 要るもの

```sh
python3 -m venv ~/.venv/ansible
~/.venv/ansible/bin/pip install ansible-core
~/.venv/ansible/bin/ansible-galaxy collection install vultr.cloud
export VULTR_API_KEY=...        # 管理画面の Account > API で作る
```

API 鍵には**繋ぐ側の住所を許可リストに入れる欄がある**。既定では自分の
IP しか通らないので、手元の回線から叩くならそこに足しておく。

`plan` の既定 `vc2-1c-0.5gb-v6` は **IPv4 が付かない**。手元から IPv6 で
出られないと ssh も届かない。無理なら [`group_vars/all.yml`](group_vars/all.yml)
で `vc2-1c-0.5gb` ($3.50/月、ewr のみ) か `vc2-1c-1gb` ($5/月、nrt と itm が
使える) に替える。

## イメージを焼く

`mkimg.sh` は NetBSD の上でしか動かない (`vnconfig` `disklabel` `installboot`
が要る)。`PROFILE=vultr` を付けると VPS 向けの版になる。

```sh
# NetBSD 機で、root で
PROFILE=vultr sh mkimg.sh amd64 10.1
```

### CI で焼く

手元に NetBSD の機械が無くても組める。runner は Linux だが、release に
置いてある NetBSD のイメージを QEMU で起こし、**その中で `mkimg.sh` を
走らせて**出来たものを ssh 越しに持ち帰れば同じことになる。
[`build-vultr-image`](../.github/workflows/build-vultr-image.yml) が
それをする。

```sh
gh workflow run build-vultr-image \
    -f arch=amd64 -f release=10.1 \
    -f authorized_key="$(cat ~/.ssh/id_rsa.pub)"
```

`vultr` という別の release に上がる。**鍵を焼いたイメージなので、`images`
とは分けてある。** 取り込みが済んだら asset は落とすこと (snapshot さえ
出来ていれば立て直せる)。

焼いたイメージが起動するかも、そのまま QEMU で確かめて画面を artifact に
残す。VGA しか出ていないので読む手はこれしかないが、`root device:` で
止まっているのか multi-user まで行ったのかはこの一枚で分かる。

いつもの版との違いは四つ。どれも Vultr 側の都合で、理由は `mkimg.sh` の
`PROFILE` のところに書いてある。

| | qemu | vultr |
| --- | --- | --- |
| 大きさ | 12 GiB | 1.75 GiB (X を落とす) |
| root | `sd0a` (virtio-scsi) | `ld0a` (virtio-blk) |
| コンソール | `consdev=com0` | 既定のまま (VGA) |
| 出来上がり | `.img.gz` | `.img` (raw のまま) |

小さいのは置き場の都合で、大きいのは Vultr 側の都合ではない。10GB の
ディスクに 1.75GiB を書くので残りは空いたままになるが、**起動すると自分で
広がる。** 焼いてある `rc.d/growlabel` が disklabel をディスク一杯まで伸ばし、
続けて NetBSD 標準の `resize_root` が fs を伸ばす。そのために一度だけ再起動
するので、初回だけ二回上がる。

ここには以前「使うなら MBR と disklabel を広げて `resize_ffs` を掛ける」と
書いてあった。**そのとおりにやると壊れる。** instance にはその root しか無く、
それは mount されている。mount した fs に `resize_ffs` は拒否を返さず、伸ばした
と言うのに `dumpfs` で見ると元の大きさのままで、書いた瞬間に bitmap が食い違い
fsck が `UNRESOLVED INCONSISTENCIES REMAIN` を出す。カーネルが抱えている古い
superblock が後から書き戻されるためで、qemu で再現して確かめた。

だから伸ばせるのは root がまだ read-only の起動途中だけ、しかも伸ばした直後に
`reboot -n` して落とす必要がある。`rc.d/resize_root` がその位置に居るので、
足りない label の側だけ `growlabel` で補い、`resize_root_postcmd` で落として
いる。

## 置き場

Vultr が取りに来るので、**認証もクエリ文字列も付かない公開 URL**が要ります。
GitHub の release に置けますが、**そのままの URL は使えません。**

```
https://github.com/.../amd64-10.1-vultr.img
  → 302 → https://release-assets.githubusercontent.com/...?<署名付きクエリ>
```

**Vultr の取り込みは 302 を追いません。** 追えないと snapshot は `pending` に
なった直後に黙って消され、API はエラーを返しません。待っている側からは
固まったようにしか見えません。[up.yml](up.yml) が渡す前に `curl -sIL` で
最終 URL を解決しているのはこのためです。クエリ文字列そのものは通ります
(署名付き URL で取り込めることを確認済み)。

asset は一つ 2GiB まで、しかも Vultr は gz を受け取りません。1.75 GiB に
切ってあるのはこの二つに挟まれた結果で、余裕は 250MB ほどしかありません。

```sh
gh release upload vultr amd64-10.1-vultr.img --repo <owner>/netbsd-ci-images
```

## 走らせる

```sh
cd vultr
ansible-playbook up.yml -e image_url=https://github.com/.../amd64-10.1-vultr.img
```

一度取り込んだ snapshot は残るので、二度目からは `image_url` は要らない。

```sh
ansible-playbook down.yml                        # instance だけ壊す
ansible-playbook down.yml -e drop_snapshot=true  # snapshot も落とす
```

instance は時間割 ($0.003/時) なので、触り終えたら壊しておく。一時間で
一円に届かない。snapshot の保管は $0.05/GB/月。

## 実際に通したときに分かったこと

一度通してあります。当たったところと、外していたところ。

- **root は `ld0a` で合っていた。** Vultr は virtio-blk で見せる。実機でも
  MBR から起動して multi-user まで行った
- **MBR/BIOS の snapshot は通る。** Vultr の移行案内は「UEFI であること」と
  書いているが、API の `uefi: false` で問題なく取り込まれる
- **Vultr は RA を流している。** `ip6mode=autohost` で住所は付く
- **しかし住所が API の `v6_main_ip` と食い違う。** dhcpcd の既定 `slaac
  private` が RFC 7217 の乱数識別子を使うのに対し、Vultr が台帳に載せるのは
  MAC から EUI-64 で作った住所。/64 は丸ごと経路付けされているので通信は
  できるが、API から住所を引いて ssh する側からは繋がらない機械に見える。
  `mkimg.sh` が `slaac hwaddr` に書き換えているのはこのため
- **`rc.conf` が既定を読んでいなかった。** これは別のバグで、通信は止めない。
  `motd` が `NetBSD ?.?` のままなのと、起動のたびに
  `$foo is not set properly` が十数行流れるのがそれ

残っているのは IPv4 付きの plan を試していないことくらいで、そちらは DHCP
なので素直に通るはず。
