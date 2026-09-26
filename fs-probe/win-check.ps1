# Linux (ntfs-3g) が書いた NTFS を Windows の chkdsk にかけ、書いたはずの
# 中身が Windows から同じに読めるかを突き合わせる。
#   pwsh win-check.ps1 <indir> <outdir>
param([string]$In, [string]$Out)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force $Out | Out-Null
$In = (Resolve-Path $In).Path; $Out = (Resolve-Path $Out).Path

# ドライバごとに alma-ntfs-<drv>.vhd と win-ntfs-<drv>.vhd が在る。
foreach ($f in Get-ChildItem -LiteralPath $In -Filter *.vhd) {
	$name = $f.BaseName
	$vhd = $f.FullName
	$r = Join-Path $Out "$name.check"
	if (!(Test-Path $vhd)) { "== ${name}: no image" | Tee-Object $r; continue }
	$log = @("== $name")
	Mount-DiskImage -ImagePath $vhd | Out-Null
	$part = Get-DiskImage -ImagePath $vhd | Get-Disk | Get-Partition | Where-Object Type -ne 'Reserved' | Select-Object -First 1
	if (-not $part.DriveLetter -or $part.DriveLetter -eq [char]0) {
		$part | Add-PartitionAccessPath -AssignDriveLetter
		$part = Get-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber
	}
	$d = "$($part.DriveLetter):"
	$log += "-- chkdsk $d (read-only)"
	$log += (chkdsk $d 2>&1 | Out-String)
	$log += "chkdsk exit $LASTEXITCODE"

	$root = "$d\linux"
	$m = Join-Path $In "$name.linux.manifest"
	if ((Test-Path $root) -and (Test-Path $m)) {
		$want = Get-Content -Encoding utf8 $m | Where-Object { $_ -like 'H|*' }
		$got = Get-ChildItem -LiteralPath $root -Recurse -Force -File -Attributes !ReparsePoint -ErrorAction Continue |
			ForEach-Object {
				$rel = './' + $_.FullName.Substring($root.Length + 1).Replace('\', '/')
				try { 'H|' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower() + '|' + $rel }
				catch { "E|$($_.Exception.Message)|$rel" }
			}
		[IO.File]::WriteAllLines((Join-Path $Out "$name.linux.back"), [string[]]$got, [Text.UTF8Encoding]::new($false))
		$diff = Compare-Object ([string[]]$want) ([string[]]$got)
		$log += "-- linux/: H lines written by Linux $($want.Count), read by Windows $($got.Count), differing $(@($diff).Count)"
		$log += ($diff | Select-Object -First 60 | Format-Table -AutoSize | Out-String -Width 400)
		$log += "-- linux/ top level as Windows sees it"
		$log += (Get-ChildItem -LiteralPath $root -Force -ErrorAction Continue | Format-Table Mode, Length, Name -AutoSize | Out-String -Width 400)
	}
	if (Test-Path "$d\src") {
		$m = Join-Path $In 'win-ntfs.manifest'
		$want = Get-Content -Encoding utf8 $m
		$got = Get-ChildItem -LiteralPath "$d\src" -Recurse -Force -File -Attributes !ReparsePoint |
			ForEach-Object { 'H|' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower() + '|./' + $_.FullName.Substring($d.Length + 5).Replace('\', '/') }
		$log += "-- src/ after Linux wrote beside it: differing $(@(Compare-Object ([string[]]$want) ([string[]]$got)).Count)"
		$log += ((Get-Item -LiteralPath "$d\src\ads.txt" -Stream * | Format-Table Stream, Length -AutoSize | Out-String))
	}
	Dismount-DiskImage -ImagePath $vhd | Out-Null
	$log | Set-Content -Encoding utf8 $r
	Get-Content $r
}
# chkdsk の exit 3 は「見つけた」という報告で、この step の失敗ではない。
exit 0
