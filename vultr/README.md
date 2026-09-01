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

`growlabel` が焼かれる前に作ったイメージには、この仕掛けが入っていない。
起動しても `/` は 1.75GiB のままで、`/etc/rc.d/growlabel` も無い。焼いた
日が `mkimg.sh` に `growlabel` が入るより前かどうかで決まる。**手で
`disklabel -R` して `resize_ffs` を掛けると下の理由で壊れる**ので、その
イメージは捨てて焼き直すのが早い。

`/etc/rc.d/growlabel` だけを後から置いて `growlabel=YES` を書き、二度
再起動すれば label と fs の両方が伸びる。ただし一度目の再起動で label が
伸び、二度目で `resize_root` が fs を伸ばす、という順になる。

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

`up.yml` を使わず `vultr-cli` や API を直に叩くときは、**自分で解決してから
渡すこと。** 忘れると `pending` の ID が返り、40 秒ほどで消えて
`Invalid snapshot ID.` になる。エラーメッセージは取り込み失敗を指さないので、
何が起きたか分からない。

```sh
U=$(curl -s -o /dev/null -w '%{redirect_url}' \
	https://github.com/<owner>/netbsd-ci-images/releases/download/vultr/amd64-11.0-vultr.img)
vultr-cli snapshot create-url -u "$U" -d 'netbsd-11.0-amd64'
```

署名は一時間ほどで切れるが、Vultr は受け取った直後に取りに行くので間に合う。

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

**取り込みが済んだら置き場の asset を落とすこと。** snapshot さえ在れば立て直せる
し、鍵を焼いたイメージを公開したまま残す理由も無い。`up.yml` が取り込んだ回に
だけその命令を出す。

```sh
gh release delete-asset vultr amd64-11.0-vultr.img --repo <owner>/netbsd-ci-images --yes
```

### 同じイメージから複数台立てる

snapshot の名前は `snapshot_name` で、既定は `label` と同じ。揃えれば取り込みは
一度で済み、instance だけが増える。

```sh
ansible-playbook up.yml -e label=emacs20 -e snapshot_name=netbsd-11.0-amd64 \
    -e image_url=https://github.com/.../amd64-11.0-vultr.img
ansible-playbook up.yml -e label=emacs21 -e snapshot_name=netbsd-11.0-amd64
```

二台目は取り込み済みなので `image_url` は要らない。**揃えたときは
`down.yml -e drop_snapshot=true` を打たないこと。** まだ使っている instance の
立て直しができなくなる。落とすのは全部壊したあと。

```sh
ansible-playbook down.yml                        # instance だけ壊す
ansible-playbook down.yml -e drop_snapshot=true  # snapshot も落とす
```

instance は時間割 ($0.003/時) なので、触り終えたら壊しておく。一時間で
一円に届かない。snapshot の保管は $0.05/GB/月。

## DragonFly BSD

同じ口 (snapshot-from-URL) に、DragonFly の生イメージも流せる。

```sh
sh build-vultr-dragonfly.sh 6.4.2        # 手元 (QEMU が要る)
gh workflow run build-vultr-dragonfly \
    -f release=6.4.2 -f authorized_key="$(cat ~/.ssh/id_rsa.pub)"
```

組み方は NetBSD と違う。**DragonFly には配布セットが無い。** 公開されている
のは起動できる live の img と、その中から走らせる `installer(8)` だけで、
`installer` は DFUI 越しの対話なので応答ファイルを置く道が無い。そこで live を
QEMU で起こし、**その中で** [`dragonfly-install.sh`](dragonfly-install.sh) を
走らせて、繋いでおいた生ディスクへ handbook どおりの手順で入れる。live の
`/` を `cpdup` で写しているので、中身は配布されている live そのままになる。

| | NetBSD | DragonFly |
| --- | --- | --- |
| 元 | 配布セットを展開 (`mkimg.sh`) | live img を写す (`dragonfly-install.sh`) |
| 組む場所 | NetBSD ゲストの中 | DragonFly ゲストの中 |
| 大きさ | 1.75 GiB | 1 GiB |
| root | `ld0a` | `part-by-label/DFLYVULTR.a` |
| 広げる | `rc.d/growlabel` + `resize_root` | `rc.d/growdisk` |

root は `/dev/part-by-label/DFLYVULTR.a` で指してある。ディスクの名前は繋ぎ方で
変わり (Vultr は virtio-blk なので `vbd0`、QEMU に IDE で繋げば `ad0`)、
`fstab` と食い違えば root が見つからない。label で指せば同じイメージがどちらでも
起動する。

住所については NetBSD で要った手当てが要らない。あちらは dhcpcd の既定
`slaac private` が RFC 7217 の乱数識別子を使うので、Vultr が台帳に載せる
EUI-64 の住所と食い違い、`slaac hwaddr` へ書き換えていた。DragonFly の SLAAC は
カーネルが EUI-64 で作るので、初めから台帳と同じになる。

### 起きてから自分で広がる

1 GiB で焼いてあるので、10 GB のディスクに書かれると残りは空いたまま届く。
[`rc.d/growdisk`](dragonfly-growdisk) が初回の起動で三つを順に伸ばし、一度だけ
落ちる。**初回だけ二回上がる。**

	fdisk -IB      slice 1 をディスク一杯に取り直す
	disklabel64    label を取り直し、a: を slice 一杯にする
	growfs         fs を partition 一杯にする

順番はこのとおりでないと通らない。実測で分かったのは三つ。

- **`fdisk` は mount 中のディスクにも書けて、新しい大きさはその場でカーネルに
  入る。** 書いた直後の `diskinfo /dev/vbd0s1` が 4094.97 MB を返した
- **label は自分の中に slice の大きさを控えており、`fdisk` では変わらない。**
  取り直させるには `disklabel64 -r -w … auto` で書き直すしかないが、これは
  `label:` の名前も partition も消す。消したままにすると
  `/dev/part-by-label/…` が無くなって次は起動しない。名前を書き戻すまでが
  一続き
- **`disklabel64 -R` に `/dev/stdin` は渡せない。** この段では procfs も
  fdescfs もまだ乗っていないため。tmpfs を一枚借りて置き場にしている
- **label を書き直している間はディスクを読めない。** root の partition が
  カーネルから消えるので、まだ page-in していない実行ファイルがそこで読め
  なくなる。最初これで `awk` が `vnode_pager_getpage: I/O read error` と
  落ち、空の proto を渡して label を壊した。窓に入る前に、使う道具を tmpfs
  へ写してある
- **もう広げ終わったかの判定に、小さい閾値を使ってはいけない。** `fdisk -I`
  は slice をシリンダ境界で丸めるので、広げ終わった後も末尾に一シリンダぶん
  余りが残る。閾値をちょうどその 2048 sector にしていたため、二度目の起動でも
  「まだ広げられる」と読んで label を書き直し、`growfs` は伸びないので reboot
  もせず、書き直したせいで root を rw に出来ずに single user へ落ちた

label を書き直した後は、`growfs` が失敗しても必ず落とす。書き直した時点で
root の device が別物になっており、`rc.d/root` の `mount -u -o rw /` が

	cannot update mount, v_rdev does not match
	specified device does not match mounted device

で撥ねられる。戻れる道は落とすことしかない。

`growfs` を掛けられるのは root がまだ read-only の間だけで、掛けた直後に
`reboot -qn` で落とす。rw で mount した fs を伸ばすと、カーネルが抱えている
古い superblock が後から書き戻されて壊れる。NetBSD で `resize_ffs` を掛けたとき
と同じ話で、`sync` してはいけないのも同じ。

### 確かめ方

```sh
sh verify-vultr-dragonfly.sh 6.4.2 10    # 10 GiB のディスクに置いて起こす
```

焼いた raw を大きなファイルの先頭に置き、Vultr が書き戻したのと同じ形にして
起こす。見るのは、落ちて上がり直してくるかと、`/` がディスク一杯になって
いるかの二つ。1 GiB で焼いたものが 10 GiB になっていれば、growdisk が走った
以外に説明が付かない。

**loader には何も打たない。** コンソールは焼いた側が VGA のままなので (Vultr に
シリアルが無い)、シリアルで中を見るには loader の促しで
`set console="comconsole"` と打つことになる。ところが**この loader は促しを出した
直後の何文字かを落とす**。`boot` が `bot` に、次は `oot` になって
`unknown command` で止まった。打鍵の間隔を 0.08 秒から 0.2 秒に伸ばしても直らない。

悪いのは、促しに落とすと自動起動の待ち時間も止まることで、一文字落とした時点で
その機械は永久に上がってこない。**見るために打った結果、見る対象が起動しない。**
だから何も打たず、10 秒待って勝手に起動させ、中は ssh で見る。上がってこなかった
ときだけ QEMU のモニタから画面を一枚撮る ([`screendump.py`](../screendump.py))。
single user に落ちていたのは、この一枚で分かった。

CI は二度組む。出す版に焼くのは渡された公開鍵なので、runner にその秘密鍵は無く、
ssh で入れない。確かめる版だけ使い捨ての鍵で組み、同じスクリプト・同じ大きさ・
同じ版で、違うのは焼いた公開鍵だけにしてある。出す版そのものにも一度火を入れて
画面を撮る。

### まだ通していないところ

- **本物の Vultr に立てていない。** 確かめたのは QEMU に virtio-blk で繋いだ
  ところまでで、snapshot の取り込みから先は NetBSD と同じ口を通るはずという
  だけ
- `up.yml` は instance を立てるところまでは OS を選ばないが、**そのあとの
  アカウントを作る段は NetBSD 前提**。[`files/setup-accounts.sh`](files/setup-accounts.sh)
  が `groupadd` と `useradd` を呼ぶが、DragonFly にあるのは `pw`
- swap は切ってある。一番安い plan は 512MB しかないので、要るなら立ててから
  `swapfile` を足すこと

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
