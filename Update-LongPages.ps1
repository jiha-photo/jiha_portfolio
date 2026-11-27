# V31.1.3 - LONG PAGE AUTO PROCESSOR

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

$root = (Get-Location).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)

$base = 'assets/other/portfolio-auto'
$longBase = "$base/longpages"
$indexPath = "$base/longpage-index.json"

New-Item -ItemType Directory `
    -Path $longBase -Force | Out-Null

$manifest = ConvertFrom-Json -InputObject (
    [IO.File]::ReadAllText(
        (Join-Path $root "$base/manifest.json")
    )
)

$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
$ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue

if (!$ffmpeg -or !$ffprobe) {
    throw "FFmpeg and FFprobe are required."
}

$ff = $ffmpeg.Source
$fp = $ffprobe.Source

function Get-Dimensions([string]$path) {

    $size = @(
        & $fp -v error `
            -select_streams 'v:0' `
            -show_entries 'stream=width,height' `
            -of 'csv=p=0:s=x' `
            $path
    )

    if (
        $LASTEXITCODE -ne 0 -or
        $size.Count -eq 0 -or
        $size[0] -notmatch '^(\d+)x(\d+)$'
    ) {
        throw "Cannot read image dimensions: $path"
    }

    return [PSCustomObject]@{
        width = [int]$Matches[1]
        height = [int]$Matches[2]
    }
}

# Preserve existing long pages across PCs.

$longIndex = @{}

if (Test-Path -LiteralPath $indexPath) {

    $previous = ConvertFrom-Json -InputObject (
        [IO.File]::ReadAllText(
            (Join-Path $root $indexPath)
        )
    )

    foreach ($property in $previous.PSObject.Properties) {

        $longIndex[$property.Name] = $property.Value
    }
}

# Index local original images by SHA256.

$originals = @{}

foreach ($folder in @(
    '시즌프로모션용',
    '상세페이지용'
)) {

    if (!(Test-Path -LiteralPath $folder)) {
        continue
    }

    foreach ($file in @(
        Get-ChildItem `
            -LiteralPath $folder `
            -File -Recurse |
        Where-Object {
            $_.Extension -match '^\.(jpg|jpeg|png|webp|bmp|tif|tiff)$'
        }
    )) {

        $hash = (
            Get-FileHash `
                -LiteralPath $file.FullName `
                -Algorithm SHA256
        ).Hash.ToLower()

        $originals[$hash] = $file.FullName
    }
}

$processed = 0
$cached = 0
$segments = 0
$unavailable = 0

$seen = @{}

foreach ($project in @($manifest.items)) {

    if ($project.section -notin @('promo','detail')) {
        continue
    }

    foreach ($media in @($project.media)) {

        if ($media.type -ne 'image') {
            continue
        }

        $hash = [string]$media.hash

        if (
            !$hash -or
            $seen.ContainsKey($hash)
        ) {
            continue
        }

        $seen[$hash] = $true

        # Reuse previously generated long pages.

        if ($longIndex.ContainsKey($hash)) {

            $record = $longIndex[$hash]
            $valid = $true

            foreach ($part in @($record.sections) + @($record.href)) {

                if (
                    !$part -or
                    !(Test-Path -LiteralPath $part -PathType Leaf)
                ) {
                    $valid = $false
                    break
                }
            }

            if ($valid) {

                $cached++
                continue
            }
        }

        if (!$originals.ContainsKey($hash)) {

            if (Test-Path -LiteralPath $media.image) {

                $webSize = Get-Dimensions $media.image

                if (
                    $webSize.height / $webSize.width -ge 3
                ) {

                    $unavailable++

                    Write-Warning (
                        "Original unavailable: " +
                        $project.title + " / " + $media.name
                    )
                }
            }

            continue
        }

        $source = $originals[$hash]

        $size = Get-Dimensions $source

        $w = $size.width
        $h = $size.height

        if (
            $w -le 0 -or
            $h -le 0
        ) {
            throw "Invalid image dimensions."
        }

        # Long image threshold: height >= 3 x width.

        if ($h / $w -lt 3) {
            continue
        }

        if ($w -gt 16383) {
            throw "Image width exceeds WebP limit: $source"
        }

        $key = $hash.Substring(0,32)

        $folder = "$longBase/$key"

        New-Item -ItemType Directory `
            -Path $folder -Force | Out-Null

        $parts = New-Object System.Collections.ArrayList

        $maxHeight = 2000
        $index = 0

        Write-Host ""
        Write-Host "LONG PAGE: $($project.title)" `
            -ForegroundColor Cyan

        Write-Host "SOURCE   : $w x $h"

        for ($y = 0; $y -lt $h; $y += $maxHeight) {

            $index++

            $slice = [math]::Min(
                $maxHeight,
                $h-$y
            )

            $name = 'section-{0:D3}.webp' -f $index

            $out = "$folder/$name"

            $tmp = "$folder/section-$index.tmp.webp"

            # Crop only. Never resize original pixels.

            $filter = "format=bgra,crop=${w}:${slice}:0:${y}:exact=1"

            & $ff -hide_banner -loglevel error -y `
                -i $source `
                -map '0:v:0' `
                -vf $filter `
                -frames:v 1 `
                -c:v libwebp `
                -quality 92 `
                -compression_level 6 `
                $tmp

            if (
                $LASTEXITCODE -ne 0 -or
                !(Test-Path -LiteralPath $tmp)
            ) {
                throw "Long page conversion failed: $source"
            }

            $check = Get-Dimensions $tmp

            if (
                $check.width -ne $w -or
                $check.height -ne $slice
            ) {
                throw "Section dimension mismatch: $tmp"
            }

            if ((Get-Item -LiteralPath $tmp).Length -ge 95MB) {
                throw "Section exceeds GitHub size limit."
            }

            Move-Item `
                -LiteralPath $tmp `
                -Destination $out -Force

            [void]$parts.Add($out)

            $segments++

            Write-Host "SECTION $index : $w x $slice"
        }

        # Standalone scroll viewer

        $page = @"
<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Promotion - Full View</title>
<style>
*{box-sizing:border-box}
html,body{margin:0;padding:0;background:#f4f3f1}
main{width:100%;max-width:${w}px;margin:auto;background:white}
img{display:block;width:100%;height:auto;margin:0;padding:0;border:0}
</style>
</head>
<body>
<main>
"@

        foreach ($part in $parts) {

            $filename = Split-Path $part -Leaf

            $page += (
                '<img src="' +
                $filename +
                '" alt="" decoding="async" loading="lazy">' +
                "`n"
            )
        }

        $page += '</main></body></html>'

        $href = "$folder/index.html"

        [IO.File]::WriteAllText(
            (Join-Path $root $href),
            $page,$utf8
        )

        $longIndex[$hash] = [PSCustomObject]@{
            hash = $hash
            width = $w
            height = $h
            count = $parts.Count
            image = $parts[0]
            href = $href
            sections = @($parts.ToArray())
        }

        $processed++
    }
}

$json = ConvertTo-Json `
    -InputObject $longIndex `
    -Depth 15

$tmpIndex = "$indexPath.tmp"

[IO.File]::WriteAllText(
    (Join-Path $root $tmpIndex),
    $json,$utf8
)

Move-Item `
    -LiteralPath $tmpIndex `
    -Destination $indexPath -Force

Write-Host ""
Write-Host "=== LONG PAGE RESULT ===" `
    -ForegroundColor Green

Write-Host "NEW LONG PAGES : $processed"
Write-Host "CACHED PAGES   : $cached"
Write-Host "NEW SECTIONS   : $segments"
Write-Host "TOTAL ARCHIVE  : $($longIndex.Count)"
Write-Host "SOURCE MISSING : $unavailable"
Write-Host "ORIGINALS      : Preserved"