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

**取得元はこのリポジトリに書きません。** 入口 (`MEDIA_BASE`) も、その下の
階層 (`media-paths.conf`) も、環境と secret から渡します。どちらも既定値を
持たず、対応表は `.gitignore` 済みです (見本は `media-paths.conf.example`)。
public なリポジトリでは、スクリプトも実行ログも誰でも読めるためです。

公開できない OS も **CI の上で組んで ssh まで確かめます** (`verify-images`
workflow)。ただし何も残しません。イメージも媒体も release にも artifact にも
上げず、job の最後に消します。残るのは「通ったかどうか」の一行だけです。
ログに取得元が出ないよう、secret による伏字に加えて `::add-mask::` で入口・
ホスト名・階層を登録し、`curl` の進捗表示を止め、失敗メッセージからも伏せて
います。

手元で回すと TCG で遅く、機械も塞がります。CI なら並行して回せます。ただし
速くなるのは x86 のゲストだけで、sparc や hppa は CI でも TCG です。

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

### 他の OS

`build.sh` の driver は四つ。`prebuilt` (展開済みイメージ)、`install`
(インストーラを操って空のディスクに入れる)、`anita` (NetBSD)、`autoinstall`
(OpenBSD)。

`targets/<名前>.conf` と `build.sh` で組む。手でコンソールに通した手順を
そのまま `STEPS` に書き写す形。

| target | emulator | ssh | 状態 |
| --- | --- | --- | --- |
| freebsd-14.3-amd64 | QEMU x86_64 | ○ | **通った**。公式 VM イメージから、取得・起動・鍵配り・ssh まで一続きで確認 |
| dragonfly-6.4.2-x86_64 | QEMU x86_64 | ○ | **通った**。公式 img から。loader のメニューに console の切替が無いので ESC で促しに落とす。打鍵が速いと boot が bot になって取りこぼす |
| sunos-4.1.4-sparc | QEMU SS-5 | ○ | **通った**。当時の OpenSSH 5.4p1 のバイナリを TFTP で持ち込んで据えた (下記) |

## 実測で分かった詰まりどころ

机上では出てこなかったもの。同じ所で止まらないよう道具側に入れてある。

| 症状 | 正体 |
| --- | --- |
| x86 のゲストがシリアルに一文字も出さない | VGA が在ると firmware も loader も画面側にしか出さない。`-vga none` でも変わらず、`-nographic` のときだけシリアルに出る。`-nographic` は標準入出力を使うので socket では繋げず、書き出しはファイル、打ち込みは FIFO にする (`CONSOLE=stdio`) |
| FreeBSD の loader メニューで Enter が効かない | loader は CR を待っており LF では動かない。メニューの番号を押す |
| 「Cons: Dual」に一致しない | メニューは色と桁送りを挟むので、生のままでは `C` と `ons: Dual` の間にエスケープが入る。照合の前に制御列を落とす |
| 長い行を打つと途中で止まる | 古いブートローダは続けて流し込むと取りこぼす。FreeBSD の loader は `set console="comconsole"` の途中で落とし、閉じ引用符を待ったまま止まった。一文字ずつ送る (`SLOW`) |
| ゲストが取ってきた鍵で入れない | 鍵を配る番号 (8123) を別のセッションが握っており、ゲストは向こうの鍵を取っていた。番号は空いているものを借りる |
| `unbound variable` で止まる | 変数の直後に日本語を書くと、macOS の bash が多バイト文字を変数名に含める。`${VAR}` と括る |
| 起動の最初の数百バイトが一文字も届かない | `-nographic` の qemu の標準出力をファイルに向けると、libc のブロックバッファ (4 KB) に溜まったまま出てこない。よく喋る相手は溢れて流れるので気付かないが、MidnightBSD の boot2 は 600 バイトほどしか出さず、全部バッファの中で止まっていた。**pty の上で起こす** (`talk.py --spawn`) と行ごとに流れる |
| 促しを取り落とす | 一手当たるたびに読んだものを全部捨てていた。同じ一塊に次の促しが入っていると消える。MidnightBSD の `boot:` が実際にそれで消えた。当たった位置より後ろは残す |
| MidnightBSD が起動の途中から黙る | boot2 は喋るが loader は画面側にしか出さない。spinner の間に **空白を二回** 送ると `boot:` の促しが出るので、そこで `-h` を渡すとシリアルに切り替わる |
| 手順の一行がパイプで切れる | 段の区切りに `\|` を使っていたため。区切りを改行にした |
| ゲストが荷物を受け取れない | SunOS 4 の `ftp` は FTP しか喋らず HTTP を引けない。ラベルの無い生の tar を追加ディスクにしても、SunOS が開かない (`corrupt label`)。**qemu 内蔵の TFTP** で渡す (8.8 MB が 6 秒) |
| 鍵を置いたのに `Permission denied` | 二つ原因があった。SunOS 4 の root の home は `/etc/passwd` で `/` (「/root」ではない)。さらに macOS で作った tar には作成者の uid が入り、`tar xpf` がその uid のまま展開するので sshd が `bad ownership or modes` と言って読まない。`--uid 0 --gid 0` で焼き、ゲストでも `chown` する |
| 古い機械で `ssh-keygen` が返ってこない | `/dev/urandom` が無く、OpenSSH は外部コマンドの出力から entropy を集める。**host key はホスト側で作って持ち込む** (書式は PEM)。集める一覧を削るのは駄目で、`PRNG initialisation failed` になる |

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

## CI に移したもの

手元で通ったもののうち、**license=free のものは CI で組む** (`build-os-images`
workflow)。runner は x86_64 の Linux で KVM が使えるので、手元 (Apple
Silicon の TCG) では数分かかっていた x86 のゲストがほぼ実速で動く。

同じ `targets/<名前>.conf` を手元でも CI でも読む。CI は plan の段で
`LICENSE=free` 以外を弾くので、手元専用のものが紛れ込んで公開されることは
ない。

配るイメージには仕込みを焼く (`PERSIST=yes`)。起こしただけで ssh に入れない
と、使う側が毎回 loader を叩くことになるため。鍵そのものは焼かず、起動の
たびに 10.0.2.2:8123 から取りに行く仕掛けだけを置く (NetBSD のイメージと
同じ形)。

release の資産は 1 ファイル 2 GiB までなので、圧縮した qcow2 に固めてから
上げる (FreeBSD の生イメージは 6 GiB ある)。

## 手元の媒体 (公開しない側)

`disk_images/` にあるもの。`.gitignore` に入れてあり、リポジトリには
入りません。**「既にイメージの形をしているもの」から手を付けます**。組み立て
より、起動して ssh を通すほうが主作業になるためです。

| ある物 | 使い道 | 状態 |
| --- | --- | --- |
| SunOS 4.1.4 の完成イメージ | QEMU sparc で SunOS 4.1.4 | **ssh まで通った**。専有 PROM は不要で QEMU 同梱の OpenBIOS で起きる。gcc は無く `/bin/cc` は K&R なので組めないが、当時ビルドされた OpenSSH 5.x のバイナリ (OpenSSL は静的リンク済み) を TFTP で持ち込んで据えた |
| HP-UX 10.20 の完成イメージ | QEMU hppa で HP-UX 10.20 | 同上。**root はパスワード無し**、バンドルの `/usr/bin/cc` で C が通る (K&R 止まり) |
| HP-UX 11.11 の完成イメージ | QEMU hppa で HP-UX 11.11 | **root で入れるところまで通った** (パスワードは `root`)。**`/usr/local/bin/gcc` 4.0.4 と `gmake` `gtar` `gzip` が最初から入っている**。pkgsrc が公式に見ているのも 11.x で、PA-RISC 用の gcc 4.2.3 が別途配られてもいる |
| IRIX の導入済み CHD 二つ | MAME で IRIX。PROM も別に持っている | MAME の扱いを覚える最初の一台に向く |
| Sun3 と Sun3x の素材 | TME か MAME の sun3 | 素材のみ。入れ方は自前 |
| NWS-5000X の ROM と NEWS-OS の媒体 | MAME の **`nws5000x`** (`news_r4k`) | **NEWS-OS 4.2.1R が起動し、root で入れた**。ROM 三つの SHA1 は MAME の定義と一致。導入済み CHD があるので install は要らない。**mule 2.3 がここでビルド・ダンプ・起動まで通った** (`/bin/cc` = MIPS RISCompiler 2.11、1993 年) |
| `UnixWare/`, `SCO_OpenServer/`, `QNX/` の ISO | i386 なので QEMU で入る | **UnixWare 7.1.1 と QNX 6.3.2 はインストーラが起動する**ところまで確認。SCO OpenServer 6 は未確認 |
| `Tru64/`, `AIX/` の ISO | 上の「届かないもの」を参照 | 見込み薄 |

ssh は、ベンダの sshd が無い世代では **pkgsrc を bootstrap して入れます**
(NetBSD 以外でも pkgsrc は動きます)。それも通らなければ「作れない」側へ
移します。

## 相手ごとの癖 (踏んだもの)

一度踏むと二度目は避けられるものを、踏んだ順に置きます。

| 相手 | 癖 |
| --- | --- |
| **Sony NEWS (MAME)** | CD からの読み出しが **8MB で頭打ち**になる。36MB のファイルが 7.49MB で切れ、生デバイスから `dd` しても 3971 ブロックで止まる。荷物は **2 台目の SCSI ディスクを生のまま挿して `dd`** で渡す (`-scsi0:1 harddisk -hard2 <生の tar>`) |
| **Sony NEWS (NEWS-OS)** | ゲストの時計が **1993 年**で起きる。tar の中の 1995 年のファイルのほうが新しくなり、`configure` が作った `config.h` を make が「古い」と見て拒む。`date 9908161700` で 1999 年にする (2 桁年なので 1970-1999 しか表せない)。shell は csh で `2>&1` が通らない |
| **HP-UX 11.11** | **Ignite-UX のインストーラは qemu-hppa で動かない**。B160L は `Scanning system for IO devices` から進まず、C3700 はデバイス列挙の直後に `Data page fault` で panic する (NIC を外しても同じ番地)。**完成イメージなら B160L で起動する** |
| **HP-UX (完成イメージに添えられた run.sh)** | `-d nochain` が付いている。落とすと `Checking root file system` から進まなくなった (41 時間放置して変化なし)。引数を書き写すときに落とさないこと |
| **HP-UX (ゲストへの荷物)** | ゲストの DNS が QEMU の stub (10.0.2.3) に届かず、`ftp` が名前を引けない。`wget` も `curl` も無い。**ツリーは ISO に焼いて CD として渡す**と `mount -F cdfs -o ro /dev/dsk/c0t2d0` で読める。生ディスクを増やす手は使えない -- SCSI の若い id にディスクを足すと firmware がそちらから起動しようとして `LIF magic` で止まる (CD なら起動候補にならない) |
| **HP-UX (置き場所)** | pkgsrc のツリーは展開に **約 1.3G** 要る。既定の切り方では `/var` に 716M しか無く `No space left on device` で落ちる。`/home` (2.0G 空き) か `/usr` (2.9G 空き) へ置く。`/home` を選んだのは、中身が空でツリーごと捨てられるため。`/usr` は OS の側なので混ぜない |
| **UnixWare 7.1.1** | ライセンス画面は `<F8>` で 60 日評価に逃げられる。NIC は **`pcnet`** を挿しておく (無いまま入れると導入の途中で "No network adapter" になり、後から足せない)。画面は F10 で進む |
| **QNX 6.3.2** | ブートメニューは `f3` を送ってから `3` を送ると通る。出揃う前の打鍵は捨てられる。媒体は Momentics 版なのでコンパイラが付いてくる |

## 未確認・調べること

- NetBSD 0.8 / 0.9 の入手元 (公式ミラーには無い)
- MAME で NetBSD や IRIX が実際に起動するか。NEWS は `-video none` と
  `-serial0 null_modem -bitb socket.127.0.0.1:4000` で外から喋れた (MAME 側が
  listen する)。IRIX の Indy にはシリアルのスロットが無く、PROM の設定を
  画面越しに入れる必要がある
- TME が今の Ubuntu で建つか
- QNX 6.3 / UnixWare / SCO の取得が配布元の規約に触れないか
- pkgsrc の bootstrap が IRIX 6.5 / HP-UX 10.20 / SunOS 4.1.4 で通るか。
  HP-UX 11.11 では、ツリーを `/home` へ置いて `--prefix=/opt/pkg` で試している最中
- SunOS 4.1.4 で ssh の接続ごとに entropy を集め直す作りのため、接続に
  時間がかかる。実用上の当たりを測る
- MidnightBSD 4.0.7 (i386) は boot2 までは喋る。spinner の間に空白を二回
  送ると `boot:` の促しが出て、そこに `-h` を渡せる。**ところがその先の
  loader が画面側から離れない。** `-h` でも変わらず、IDE でも USB でも同じ。
  次の手は、動いている FreeBSD のゲストに媒体を繋いで `/boot/loader.conf` に
  `console="comconsole"` を書き足すこと (builder-vm の考え方)。そこまで
  やらないとインストーラの画面が見えない
