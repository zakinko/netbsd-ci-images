# Linux の ntfs3 が作った symlink を Windows が辿れるかを見る。
#   pwsh win-links.ps1 <indir> <outdir>
# <indir> の *-links.vhd ごとに、\links の下の各 link について、Windows の
# 見る種別と先、開いて読めた一行目 (読めなければその error) を書き出す。
param([string]$In, [string]$Out)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force $Out | Out-Null
$In = (Resolve-Path $In).Path; $Out = (Resolve-Path $Out).Path

foreach ($f in Get-ChildItem -LiteralPath $In -Filter *-links.vhd) {
	$name = $f.BaseName
	$log = @("== $name")
	Mount-DiskImage -ImagePath $f.FullName | Out-Null
	$part = Get-DiskImage -ImagePath $f.FullName | Get-Disk | Get-Partition | Where-Object Type -ne 'Reserved' | Select-Object -First 1
	if (-not $part.DriveLetter -or $part.DriveLetter -eq [char]0) {
		$part | Add-PartitionAccessPath -AssignDriveLetter
		$part = Get-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber
	}
	$d = "$($part.DriveLetter):"
	chkdsk $d 2>&1 | Out-Null
	$log += "$name chkdsk exit $LASTEXITCODE"
	foreach ($i in Get-ChildItem -LiteralPath "$d\links" -Force | Sort-Object Name) {
		if (-not ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
		$p = $i.FullName
		try {
			if (Test-Path -LiteralPath $p -PathType Container) {
				$n = @(Get-ChildItem -LiteralPath $p -Force -ErrorAction Stop).Count
				$r = "lists $n entries"
			} else {
				$r = "reads '" + (Get-Content -LiteralPath $p -TotalCount 1 -ErrorAction Stop) + "'"
			}
		} catch { $r = "error: $($_.Exception.Message)" }
		$log += "$name $($i.Name): LinkType $($i.LinkType) Target '$($i.Target)' dir attribute $([bool]($i.Attributes -band [IO.FileAttributes]::Directory)) -> $r"
		$log += (fsutil reparsepoint query $p 2>&1 | Select-String -Pattern 'Tag value|Substitute Name:|Print Name:|Flags' | ForEach-Object { "    " + $_.Line.Trim() })
	}
	Dismount-DiskImage -ImagePath $f.FullName | Out-Null
	$log | Set-Content -Encoding utf8 (Join-Path $Out "$name.links")
	$log
}
exit 0
