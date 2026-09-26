# Windows 自身に NTFS を作らせ、Windows でしか作れない物を入れる。
#   pwsh win-make.ps1 <outdir>
# 出すもの: win-ntfs.vhd (fixed VHD。末尾に 512 byte の footer が付いた生の
# ディスクなので、Linux は losetup -P でそのまま読める) と win-ntfs.manifest。
param([string]$Out)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$vhd = Join-Path $Out 'win-ntfs.vhd'

@"
create vdisk file="$vhd" maximum=512 type=fixed
select vdisk file="$vhd"
attach vdisk
create partition primary
format fs=ntfs quick label=WIN
assign letter=T
"@ | Set-Content -Encoding ascii "$env:TEMP\mk.dp"
diskpart /s "$env:TEMP\mk.dp"
if ($LASTEXITCODE) { throw "diskpart $LASTEXITCODE" }

$s = 'T:\src'
New-Item -ItemType Directory $s | Out-Null
Set-Location $s
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
function W($p, $v) { [IO.File]::WriteAllText([IO.Path]::Combine((Get-Location).Path, $p), $v) }
function RandFile($p, $n) {
	$b = New-Object byte[] $n; $rng.GetBytes($b); [IO.File]::WriteAllBytes($p, $b)
}
W small "hello`n"
New-Item empty -ItemType File | Out-Null
foreach ($n in 1,511,512,513,700,1023,1024,4095,4096,4097,32767,32768,32769,65536,1048575,1048577) {
	RandFile "$s\sz$n" $n
}
RandFile "$s\big64m" 67108864

# sparse: 5GiB の位置に 64KiB だけ
New-Item sparse5g -ItemType File | Out-Null
fsutil sparse setflag "$s\sparse5g" | Out-Null
$fs = [IO.File]::Open("$s\sparse5g", 'Open', 'Write')
$fs.Seek(5GB, 'Begin') | Out-Null
$b = New-Object byte[] 65536; $rng.GetBytes($b); $fs.Write($b, 0, $b.Length); $fs.Close()

New-Item -ItemType HardLink hl1 -Target "$s\small" | Out-Null
New-Item -ItemType HardLink hl2 -Target "$s\small" | Out-Null
New-Item -ItemType SymbolicLink sym_file -Target "$s\small" | Out-Null
New-Item -ItemType SymbolicLink sym_rel -Target 'small' | Out-Null
New-Item -ItemType Directory target_dir | Out-Null
W target_dir\in "in`n"
New-Item -ItemType SymbolicLink sym_dir -Target "$s\target_dir" | Out-Null
New-Item -ItemType Junction junction -Target "$s\target_dir" | Out-Null

New-Item -ItemType File ('n' * 255) | Out-Null
New-Item -ItemType File ([string][char]0x3042 * 85) | Out-Null
# UTF-16 で 255 単位、UTF-8 では 765 byte。Linux の NAME_MAX (255) を越える。
New-Item -ItemType File ([string][char]0x3042 * 255) | Out-Null
New-Item -ItemType File ([char]::ConvertFromUtf32(0x1F600) + '.txt') | Out-Null
W ([string][char]0x65E5 + [char]0x672C + [char]0x8A9E + '.txt') "ja`n"
New-Item -ItemType File 'with space' | Out-Null

New-Item -ItemType Directory many | Out-Null
0..4999 | ForEach-Object { [IO.File]::Create("$s\many\f$_").Close() }
$p = "$s\deep"
1..64 | ForEach-Object { $p = "$p\d" }
New-Item -ItemType Directory $p | Out-Null
W "$p\leaf" "bottom`n"

# 代替データストリーム
W ads.txt "main`n"
Set-Content -LiteralPath "$s\ads.txt" -Stream secret -NoNewline -Value "hidden`n"
# NTFS 圧縮 (LZNT1) と、WOF の system compression (LZX)。後者は ntfs-3g
# では plugin (ntfs-3g-system-compression) が無いと読めない。
$txt = (1..40000 | ForEach-Object { "line $_ of a compressible file" }) -join "`n"
W lznt1.txt $txt
compact /c /q "$s\lznt1.txt" | Out-Null
W lzx.txt $txt
compact /c /exe:lzx /q "$s\lzx.txt" | Out-Null
W ro.txt "ro`n"; $i = Get-Item ro.txt; $i.Attributes = $i.Attributes -bor [IO.FileAttributes]::ReadOnly
W hidden.txt "h`n"; $i = Get-Item hidden.txt; $i.Attributes = $i.Attributes -bor [IO.FileAttributes]::Hidden
W t2040 "new`n"; (Get-Item t2040).LastWriteTimeUtc = [datetime]'2040-01-01T00:00:00Z'

compact /q "$s\lznt1.txt" "$s\lzx.txt" | Set-Content -Encoding utf8 (Join-Path $Out 'win-ntfs.compact')
fsutil sparse queryrange "$s\sparse5g" | Set-Content -Encoding utf8 (Join-Path $Out 'win-ntfs.sparse')

# H 行だけを manifest.sh と同じ形で書く。reparse point は辿らない。
$lines = Get-ChildItem -LiteralPath $s -Recurse -Force -File -Attributes !ReparsePoint |
	ForEach-Object {
		$rel = './' + $_.FullName.Substring($s.Length + 1).Replace('\', '/')
		'H|' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower() + '|' + $rel
	}
[IO.File]::WriteAllLines((Join-Path $Out 'win-ntfs.manifest'), [string[]]$lines, [Text.UTF8Encoding]::new($false))
Get-ChildItem -LiteralPath $s -Force | Format-Table Mode, Attributes, Length, Name -AutoSize |
	Out-String -Width 400 | Set-Content -Encoding utf8 (Join-Path $Out 'win-ntfs.ls')
chkdsk T: | Set-Content -Encoding utf8 (Join-Path $Out 'win-ntfs.chkdsk')

Set-Location $Out
@"
select vdisk file="$vhd"
detach vdisk
"@ | Set-Content -Encoding ascii "$env:TEMP\rm.dp"
diskpart /s "$env:TEMP\rm.dp"
Get-ChildItem $Out
