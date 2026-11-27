# V31.0 - PORTFOLIO ASSET MANAGER

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

$root = (Get-Location).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)

$base = 'assets/other/portfolio-auto'
$manifestPath = "$base/manifest.json"

$brands = @(
    '자영이꺼',
    '이룸디자인스킨'
)

$categories = @(
    'own',
    '디즈니',
    '네이버웹툰',
    '이랜드',
    'K리그',
    'OTHER IP',
    '인플루언서'
)

# ==========================================
# CREATE SOURCE FOLDERS
# ==========================================

$sourceRoots = @(
    '피드게시물용',
    '릴스용',
    '시즌프로모션용',
    '상세페이지용',
    '자영이꺼SNS용'
)

foreach ($name in $sourceRoots) {

    New-Item -ItemType Directory `
        -Path $name -Force | Out-Null
}

foreach ($name in @('피드게시물용','릴스용')) {

    foreach ($cat in $categories) {

        New-Item -ItemType Directory `
            -Path "$name/$cat" `
            -Force | Out-Null
    }
}

foreach ($brand in $brands) {

    New-Item -ItemType Directory `
        -Path "시즌프로모션용/$brand" `
        -Force | Out-Null

    New-Item -ItemType Directory `
        -Path "상세페이지용/$brand" `
        -Force | Out-Null
}

foreach ($dir in @(
    '상세페이지용/기타',
    '자영이꺼SNS용/피드',
    '자영이꺼SNS용/릴스',
    "$base/images",
    "$base/videos",
    "$base/thumbnails"
)) {

    New-Item -ItemType Directory `
        -Path $dir -Force | Out-Null
}

# ==========================================
# PROTECT ORIGINAL FILES
# ==========================================

$ignorePath = '.gitignore'

$ignore = if (Test-Path $ignorePath) {

    [IO.File]::ReadAllText(
        (Join-Path $root $ignorePath)
    )

} else { '' }

foreach ($name in $sourceRoots) {

    $rule = "/$name/"

    if (($ignore -split '\r?\n') -notcontains $rule) {

        $ignore += "`r`n$rule`r`n"
    }
}

[IO.File]::WriteAllText(
    (Join-Path $root $ignorePath),
    $ignore,$utf8
)

# ==========================================
# LOAD EXISTING ARCHIVE
# ==========================================

$archive = @{}

if (Test-Path $manifestPath) {

    $old = ConvertFrom-Json -InputObject (
        [IO.File]::ReadAllText(
            (Join-Path $root $manifestPath)
        )
    )

    foreach ($item in @($old.items)) {

        if ($item) {
            $archive[[string]$item.id] = $item
        }
    }
}

$ffmpeg = Get-Command ffmpeg `
    -ErrorAction SilentlyContinue

$converted = 0
$added = 0
$reused = 0

$imageExt = '^\.(jpg|jpeg|png|webp|bmp|tif|tiff)$'
$videoExt = '^\.(mp4|mov|m4v|webm|avi|mkv)$'

function Valid-File($path) {

    return (
        (Test-Path -LiteralPath $path -PathType Leaf) -and
        ((Get-Item -LiteralPath $path).Length -gt 0)
    )
}

function Natural-Key([string]$name) {

    return [regex]::Replace(
        $name,
        '\d+',
        {
            param($m)
            $m.Value.PadLeft(16,'0')
        }
    )
}

function Convert-Media($file,$section,$role) {

    $hash = (
        Get-FileHash `
            -LiteralPath $file.FullName `
            -Algorithm SHA256
    ).Hash.ToLower()

    $key = $hash.Substring(0,32)

    $isVideo = $file.Extension -match $videoExt

    if (!$isVideo) {

        # Long product/event pages retain their dimensions.
        $longPage = (
            $section -eq 'detail' -or
            $role -eq '기획전'
        )

        if ($longPage) {

            $ext = $file.Extension.ToLower()

            if ($ext -notmatch '^\.(jpg|jpeg|png|webp)$') {

                throw "Unsupported long page format: $($file.Name)"
            }

            $out = "$base/images/$key$ext"

            if ($file.Length -ge 95MB) {

                throw "Long page exceeds 95MB: $($file.Name). Split it into sections."
            }

            if (!(Valid-File $out)) {

                Copy-Item `
                    -LiteralPath $file.FullName `
                    -Destination $out
            }

        } else {

            $out = "$base/images/$key.webp"

            if (!(Valid-File $out)) {

                if (!$ffmpeg) {
                    throw "FFmpeg is required."
                }

                $tmp = "$base/images/$key.tmp.webp"

                & $ffmpeg.Source `
                    -hide_banner -loglevel error -y `
                    -i $file.FullName `
                    -frames:v 1 `
                    -vf "scale=w='min(iw,1920)':h='min(ih,1920)':force_original_aspect_ratio=decrease" `
                    -c:v libwebp -quality 92 `
                    $tmp

                if (
                    $LASTEXITCODE -ne 0 -or
                    !(Valid-File $tmp)
                ) {

                    throw "Image conversion failed: $($file.Name)"
                }

                Move-Item -LiteralPath $tmp `
                    -Destination $out -Force
            }
        }

        return [PSCustomObject]@{
            type = 'image'
            image = $out
            hash = $hash
            role = $role
            name = $file.BaseName
        }
    }

    # VIDEO

    $out = "$base/videos/$key.mp4"
    $thumb = "$base/thumbnails/$key.webp"

    if (!(Valid-File $out)) {

        if (!$ffmpeg) {
            throw "FFmpeg is required."
        }

        $tmp = "$base/videos/$key.tmp.mp4"

        $success = $false

        foreach ($crf in @(21,24,27,30)) {

            & $ffmpeg.Source `
                -hide_banner -loglevel error -y `
                -i $file.FullName `
                -map '0:v:0' `
                -map '0:a?' `
                -vf "scale=w='min(iw,1080)':h='min(ih,1920)':force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1" `
                -c:v libx264 `
                -preset medium `
                -crf $crf `
                -pix_fmt yuv420p `
                -c:a aac `
                -movflags +faststart `
                $tmp

            if (
                $LASTEXITCODE -eq 0 -and
                (Valid-File $tmp) -and
                ((Get-Item $tmp).Length -lt 95MB)
            ) {

                $success = $true
                break
            }
        }

        if (!$success) {
            throw "Video conversion failed: $($file.Name)"
        }

        Move-Item -LiteralPath $tmp `
            -Destination $out -Force
    }

    if (!(Valid-File $thumb)) {

        if (!$ffmpeg) {
            throw "FFmpeg is required."
        }

        $tmp = "$base/thumbnails/$key.tmp.webp"

        & $ffmpeg.Source `
            -hide_banner -loglevel error -y `
            -i $out `
            -frames:v 1 `
            -vf "scale=w='min(iw,720)':h='min(ih,960)':force_original_aspect_ratio=decrease" `
            -c:v libwebp -quality 90 `
            $tmp

        if (
            $LASTEXITCODE -ne 0 -or
            !(Valid-File $tmp)
        ) {

            throw "Thumbnail conversion failed: $($file.Name)"
        }

        Move-Item -LiteralPath $tmp `
            -Destination $thumb -Force
    }

    return [PSCustomObject]@{
        type = 'video'
        image = $thumb
        video = $out
        hash = $hash
        role = $role
        name = $file.BaseName
    }
}

# ==========================================
# SCAN PROJECTS
# ==========================================

$sections = @(
    @{id='promo';root='시즌프로모션용'},
    @{id='detail';root='상세페이지용'},
    @{id='jy-sns';root='자영이꺼SNS용'}
)

foreach ($section in $sections) {

    Write-Host "`n=== $($section.id) ===" `
        -ForegroundColor Cyan

    foreach ($category in @(
        Get-ChildItem `
            -LiteralPath $section.root `
            -Directory
    )) {

        foreach ($project in @(
            Get-ChildItem `
                -LiteralPath $category.FullName `
                -Directory
        )) {

            $id = "$($section.id)/$($category.Name)/$($project.Name)"

            $media = New-Object System.Collections.ArrayList
            $seen = @{}

            if ($archive.ContainsKey($id)) {

                foreach ($item in @($archive[$id].media)) {

                    if ($item) {

                        [void]$media.Add($item)

                        $seen["$($item.hash)|$($item.role)"] = $true
                    }
                }
            }

            $files = @(
                Get-ChildItem `
                    -LiteralPath $project.FullName `
                    -File -Recurse |
                Sort-Object {
                    Natural-Key $_.FullName
                }
            )

            foreach ($file in $files) {

                $isImage = $file.Extension -match $imageExt
                $isVideo = $file.Extension -match $videoExt

                if (!$isImage -and !$isVideo) {
                    continue
                }

                if ($section.id -eq 'detail' -and !$isImage) {
                    continue
                }

                if ($section.id -eq 'jy-sns') {

                    if ($category.Name -eq '피드' -and !$isImage) {
                        continue
                    }

                    if ($category.Name -eq '릴스' -and !$isVideo) {
                        continue
                    }

                    if ($category.Name -notin @('피드','릴스')) {
                        continue
                    }
                }

                $role = if (
                    $file.DirectoryName -eq $project.FullName
                ) {

                    '기타소재'

                } else {

                    $relative = $file.FullName.Substring(
                        $project.FullName.Length+1
                    )

                    ($relative -split '[\\/]')[0]
                }

                $hash = (
                    Get-FileHash `
                        -LiteralPath $file.FullName `
                        -Algorithm SHA256
                ).Hash.ToLower()

                $signature = "$hash|$role"

                if ($seen.ContainsKey($signature)) {

                    $reused++
                    continue
                }

                Write-Host "ADD : $($project.Name) / $($file.Name)"

                $entry = Convert-Media `
                    $file $section.id $role

                [void]$media.Add($entry)

                $seen[$signature] = $true

                $added++
            }

            if ($media.Count -eq 0) {
                continue
            }

            $archive[$id] = [PSCustomObject]@{
                id = $id
                section = $section.id
                category = $category.Name
                title = $project.Name
                count = $media.Count
                media = @($media.ToArray())
            }
        }
    }
}

# ==========================================
# VALIDATE AND SAVE
# ==========================================

$items = @(
    $archive.Values |
    Sort-Object section,category,title
)

foreach ($project in $items) {

    foreach ($media in @($project.media)) {

        foreach ($p in @($media.image,$media.video)) {

            if (!$p) { continue }

            if (!(Valid-File $p)) {

                throw "Missing archive media: $p"
            }

            if ((Get-Item -LiteralPath $p).Length -ge 95MB) {

                throw "Oversize archive media: $p"
            }
        }
    }
}

$result = [ordered]@{
    version = 'V31.0-assets'
    items = $items
}

$json = ConvertTo-Json `
    -InputObject $result `
    -Depth 15

$backupDir = Join-Path `
    (Split-Path $root -Parent) `
    'portfolio-backups'

New-Item -ItemType Directory `
    -Path $backupDir -Force | Out-Null

if (Test-Path $manifestPath) {

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'

    Copy-Item `
        -LiteralPath $manifestPath `
        -Destination (
            Join-Path $backupDir `
                "portfolio-auto-$stamp.json"
        )
}

[IO.File]::WriteAllText(
    (Join-Path $root $manifestPath),
    $json,$utf8
)

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " V31.0 ASSET ARCHIVE READY" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

foreach ($section in $sections) {

    $count = @(
        $items | Where-Object {
            $_.section -eq $section.id
        }
    ).Count

    Write-Host "$($section.id) : $count projects"
}

Write-Host "ADDED MEDIA : $added"
Write-Host "REUSED      : $reused"
Write-Host "MANIFEST    : $manifestPath"
Write-Host "ORIGINALS   : Preserved"
Write-Host "INDEX HTML  : Unchanged"

# Run existing Designskin SNS updater separately
# only when local SNS media exists.

$snsMedia = @(
    Get-ChildItem `
        -LiteralPath '피드게시물용','릴스용' `
        -File -Recurse |
    Where-Object {
        $_.Extension -match $imageExt -or
        $_.Extension -match $videoExt
    }
)

if (
    $snsMedia.Count -gt 0 -and
    (Test-Path 'Update-SNS.ps1')
) {

    Write-Host "`n=== EXISTING SNS UPDATE ===" `
        -ForegroundColor Cyan

    & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File (
            Join-Path $root 'Update-SNS.ps1'
        )

    if ($LASTEXITCODE -ne 0) {
        throw "Designskin SNS update failed."
    }
}

Write-Host "`nPORTFOLIO ASSET PROCESSING COMPLETE" `
    -ForegroundColor Green

# V31.1 AUTO RENDER HOOK

Write-Host "`n=== PROMOTION AUTO RENDER ===" `
    -ForegroundColor Cyan

& (Join-Path $PSScriptRoot 'Update-Portfolio-Render.ps1')

Write-Host "`nPORTFOLIO WEBSITE UPDATED" `
    -ForegroundColor Green

Start-Process (Join-Path $PSScriptRoot 'index.html')
