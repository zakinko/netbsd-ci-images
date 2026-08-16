# どこまで出来ているか、何が出来ないか

この文書は、対応の広がりと、届かなかったものとその理由を積む場所です。
埋めながら育てます。「未確認」は未確認と書きます。

対象は「emulator の上で動き、ssh で入れる素の OS イメージ」です。

## 公開と手元

イメージや媒体には、こちらの都合とは別に配布元の都合があります。二つに
分けて扱います。

| 区分 | CI で取得・インストール・起動確認 | イメージを release に公開 |
| --- | --- | --- |
| 自由ライセンス (NetBSD FreeBSD OpenBSD DragonFly MidnightBSD Haiku Minix Plan 9 illumos 系) | する | する |
| 商用 Unix (AIX HP-UX IRIX Tru64 SunOS NEWS-OS UnixWare SCO QNX) と機器の PROM | する (下記の手当てつき) | **しない** |

商用 Unix の側は、配布元が再配布を許諾していません。媒体を集めている第三者
アーカイブにも許諾の記載はありません。**イメージを公開しない**のはそのため
です。取得と起動確認は行いますが、成果物を release にも artifact にも上げ
ない、という形にします。該当のジョブだけ private リポジトリや self-hosted
runner に寄せられるよう、レシピは同じものが両方で動くように書きます。

**取得元はこのリポジトリに書きません。** `fetch-media.sh` は `MEDIA_BASE` を
環境から受け取り、既定値を持ちません。CI では secret に置きます。public な
リポジトリでは、スクリプトも実行ログも誰でも読めるためです。

道具の側では `license:` の一語で切り替わります。public な CI は `free` の
ものだけを見ます。

## 出来ているもの

### NetBSD (anita 経由)

`ports.conf` の 14 port × ミラーに実在する版 = **719 通り**が候補。
組み立てと起動確認の道具は書けています。CI で総当たり中の結果はここに
積みます。

| port | emulator | ssh | 状態 |
| --- | --- | --- | --- |
| i386 amd64 | QEMU (KVM) | ○ | 道具は通っている。総当たりはこれから |
| sparc sparc64 alpha hppa macppc | QEMU (TCG) | ○ | 同上 |
| evbarm evbarm64 riscv64 | QEMU (TCG) | ○ | daily からのみ。release には配布物が無い |
| pmax hpcmips landisk | gxemul | **×** | 起動はする。ssh の口が作れない (後述) |
| vax | simh | **×** | 同上 |

## 届かないもの

理由の分かっているものを先に書いておきます。ここは「やってみたが駄目
だった」ではなく「原理的に届かない」ものです。

| 対象 | 理由 |
| --- | --- |
| gxemul の port (pmax hpcmips landisk) で ssh | gxemul に user networking も port forward も無い。ホストから繋ぐ口が作れない。コンソール経由でなら使える |
| simh の vax で ssh | 同上。simh の VAX の NIC は pcap 直結で、NAT が無い |
| NetBSD 1.2.1 以前 | sysinst そのものが 1.3 から。anita では入らない |
| NetBSD 1.4 以前で base の ssh | ssh が base に入るのは 1.5 から。OpenSSH を自前で組む道は用意したが、gcc 2.7 世代では通らない見込み |
| NetBSD 0.8 / 0.9 | 公式ミラーに残っていない (`archive.netbsd.org` は 1.0 から)。第三者アーカイブにも 1.0 までしか見当たらない。加えて ssh も pkgsrc も存在しない世代 |
| Tru64 を QEMU で | QEMU の alpha は SRM を持たない。手元の `firmware/es40*` は ES40 の実機用で、QEMU の clipper では使えない |
| AIX 5.3 を QEMU で | POWER の QEMU 対応が薄く、AIX が要求する機種が揃わない |

## 見込みのあるもの

まだ手を付けていないか、途中のものです。

### 他の BSD (公開できる側)

| OS | 配布物の形 | 見込み |
| --- | --- | --- |
| OpenBSD | autoinstall(8) が本体にある | i386 は既に組めている。他 port と他版へ広げる |
| FreeBSD | 10.x 以降は公式 VM イメージあり | 早い。それ以前はインストーラ自動化 |
| DragonFly BSD | 公式 img あり | 早い |
| MidnightBSD | ISO のみ | インストーラ自動化が要る |

### emulator を広げる

NetBSD 公式の[エミュレータ一覧](https://www.netbsd.org/ports/emulators.html)が
根拠になるものと、手探りのものがあります。

| emulator | 届きうる port | 根拠 |
| --- | --- | --- |
| gxemul | algor cats cobalt dreamcast evbmips netwinder pmppc prep sgimips | NetBSD 公式が動くと記載。anita は知らないので入れ方は自前 |
| QEMU | arc evbmips (mipssim) | 同上 |
| TME | sun2 sun3 | 作者自身が NetBSD の手順を公開。Ubuntu に package が無く、ソースから |
| XM6i | x68k | NetBSD/x68k を動かすために作られた emulator |
| MAME | sun2 sun3 next68k news68k newsmips luna68k hp300 sgimips mac68k x68k arc | ドライバの存在は確認済み。**NetBSD が起動するかは未確認**。公式一覧にも無い |
| ARAnyM / hatari | atari | Ubuntu に package あり。未確認 |
| fs-uae | amiga | 同上 |

いずれも anita が入れ方を知らないので、インストールを自前で書くことに
なります。共通の近道として、**amd64 のイメージを builder VM として起動し、
その中で `mkimg.sh` を回して生ディスクを組む**方法を用意する予定です。
NetBSD の `disklabel` `newfs` `installboot` が本物のまま使えるので、
emulator ごとに sysinst を操る仕掛けを書かずに済みます。

## 手元の媒体 (公開しない側)

`disk_images/` にあるもの。`.gitignore` に入れてあり、リポジトリには
入りません。**「既にイメージの形をしているもの」から手を付けます**。組み立て
より、起動して ssh を通すほうが主作業になるためです。

| ある物 | 使い道 | 状態 |
| --- | --- | --- |
| SunOS 4.1.4 の完成イメージ | QEMU sparc で SunOS 4.1.4 | 起動手順つき。**最も早い** |
| HP-UX 10.20 の完成イメージ | QEMU hppa で HP-UX 10.20 | 同上 |
| IRIX の導入済み CHD 二つ | MAME で IRIX。PROM も別に持っている | MAME の扱いを覚える最初の一台に向く |
| Sun3 と Sun3x の素材 | TME か MAME の sun3 | 素材のみ。入れ方は自前 |
| NWS-5000X の ROM と NEWS-OS の媒体 | MAME の `news_68k` / `news_38xx` | 素材は厚い。未確認 |
| `UnixWare/`, `SCO_OpenServer/`, `QNX/` の ISO | i386 なので QEMU で入る見込み | 未確認 |
| `Tru64/`, `AIX/` の ISO | 上の「届かないもの」を参照 | 見込み薄 |

ssh は、ベンダの sshd が無い世代では **pkgsrc を bootstrap して入れます**
(NetBSD 以外でも pkgsrc は動きます)。それも通らなければ「作れない」側へ
移します。

## 未確認・調べること

- NetBSD 0.8 / 0.9 の入手元 (公式ミラーには無い)
- MAME で NetBSD や IRIX が実際に起動するか、headless (`-video none`) で
  シリアルをどう引き出すか
- TME が今の Ubuntu で建つか
- QNX 6.3 / UnixWare / SCO の取得が配布元の規約に触れないか
- pkgsrc の bootstrap が IRIX 6.5 / HP-UX 10.20 / SunOS 4.1.4 で通るか
