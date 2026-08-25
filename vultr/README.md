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

いつもの版との違いは四つ。どれも Vultr 側の都合で、理由は `mkimg.sh` の
`PROFILE` のところに書いてある。

| | qemu | vultr |
| --- | --- | --- |
| 大きさ | 12 GiB | 1.75 GiB (X を落とす) |
| root | `sd0a` (virtio-scsi) | `ld0a` (virtio-blk) |
| コンソール | `consdev=com0` | 既定のまま (VGA) |
| 出来上がり | `.img.gz` | `.img` (raw のまま) |

小さいのは置き場の都合で、大きいのは Vultr 側の都合ではない。10GB の
ディスクに 1.75GiB を書くので残りは空いたままになる。使うなら MBR と
disklabel を広げて `resize_ffs` を掛ける。

## 置き場

Vultr が取りに来るので、**認証もクエリ文字列も付かない公開 URL**が要る。
GitHub の release に置くのが手近いが、**asset は一つ 2GiB まで**で、しかも
Vultr は gz を受け取らない。1.75 GiB に切ってあるのはこの二つに挟まれた
結果で、余裕は 250MB ほどしかない。

```sh
gh release upload images amd64-10.1-vultr.img --repo <owner>/netbsd-ci-images
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

## まだ確かめていないこと

**ここに書いた手順は通しで走らせていない。** 立てて初めて分かることが
三つある。

- **root が `ld0a` で合っているか。** Vultr は virtio-blk で見せているはずだが、
  実物で確かめていない。違えば `root device:` で止まる。web console に出るので
  そこで読めるし、`ROOTDEV=sd0a` を付け直して焼けばよい
- **`ip6mode=autohost` で住所が付くか。** Vultr の IPv6 が RA で降ってくる
  前提で書いてある。静的に振る作りだった場合は `/etc/ifconfig.vioif0` に
  焼き込む必要がある
- **MBR/BIOS の snapshot が通るか。** API に `uefi` の旗があり既定が false
  なので通るはずだが、Vultr の移行案内は「UEFI であること」と書いている。
  転けたら UEFI 版を焼くか、custom ISO からの sysinst に切り替える
