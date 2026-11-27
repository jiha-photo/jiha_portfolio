# V31.1.5 - CUSTOM REEL THUMBNAILS

function Update-ReelCovers {

    param(
        $Archive,
        $Categories,
        [string]$FFmpeg
    )

    $sourceRoot = '릴스용'
    $outputRoot = 'assets/other/designskin-sns/thumbnails/custom'

    $updated = 0

    if (!(Test-Path -LiteralPath $sourceRoot)) {
        return
    }

    New-Item -ItemType Directory `
        -Path $outputRoot -Force | Out-Null

    $imageExt = '^\.(jpg|jpeg|png|webp)$'
    $videoExt = '^\.(mp4|mov|m4v|webm|avi|mkv)$'

    function Select-ReelCover {

        param($Images,[string]$VideoName)

        $list = @(
            $Images | Sort-Object {
                Natural-Key $_.Name
            }
        )

        if ($list.Count -eq 0) {
            return $null
        }

        $explicit = @(
            $list | Where-Object {
                $_.BaseName -match '^(cover|thumbnail|thumb|썸네일|표지|대표이미지)'
            }
        )

        if ($explicit.Count -gt 0) {
            return $explicit[0]
        }

        if ($VideoName) {

            $matched = @(
                $list | Where-Object {
                    $_.BaseName -eq $VideoName
                }
            )

            if ($matched.Count -gt 0) {
                return $matched[0]
            }
        }

        return $list[0]
    }

    function Convert-ReelCover {

        param($File)

        $hash = (
            Get-FileHash `
                -LiteralPath $File.FullName `
                -Algorithm SHA256
        ).Hash.ToLower()

        $key = $hash.Substring(0,32)
        $out = "$outputRoot/$key.webp"

        if (!(Test-Output $out)) {

            $tmp = "$outputRoot/$key.tmp.webp"

            & $FFmpeg `
                -hide_banner -loglevel error -y `
                -i $File.FullName `
                -map '0:v:0' `
                -vf "scale=w='min(iw,1080)':h='min(ih,1920)':force_original_aspect_ratio=decrease" `
                -frames:v 1 `
                -c:v libwebp `
                -quality 92 `
                -compression_level 6 `
                $tmp

            if (
                $LASTEXITCODE -ne 0 -or
                !(Test-Output $tmp)
            ) {

                if (Test-Path -LiteralPath $tmp) {
                    Remove-Item -LiteralPath $tmp
                }

                throw "Custom thumbnail conversion failed: $($File.Name)"
            }

            Move-Item `
                -LiteralPath $tmp `
                -Destination $out -Force
        }

        return $out
    }

    Write-Host ""
    Write-Host "=== CUSTOM REEL THUMBNAILS ===" `
        -ForegroundColor Cyan

    foreach ($category in @(
        Get-ChildItem `
            -LiteralPath $sourceRoot `
            -Directory
    )) {

        if (!$Categories.ContainsKey($category.Name)) {
            continue
        }

        $cat = $Categories[$category.Name]
        $groups = @()

        # Grouped reel folders

        foreach ($folder in @(
            Get-ChildItem `
                -LiteralPath $category.FullName `
                -Directory
        )) {

            $files = @(
                Get-ChildItem `
                    -LiteralPath $folder.FullName `
                    -File -Recurse
            )

            $groups += [PSCustomObject]@{
                title = $folder.Name
                images = @(
                    $files | Where-Object {
                        $_.Extension -match $imageExt
                    }
                )
                videos = @(
                    $files | Where-Object {
                        $_.Extension -match $videoExt
                    }
                )
            }
        }

        # Standalone videos directly inside category

        $looseFiles = @(
            Get-ChildItem `
                -LiteralPath $category.FullName `
                -File
        )

        foreach ($video in @(
            $looseFiles | Where-Object {
                $_.Extension -match $videoExt
            }
        )) {

            $groups += [PSCustomObject]@{
                title = $video.BaseName
                images = @(
                    $looseFiles | Where-Object {
                        $_.Extension -match $imageExt -and
                        $_.BaseName -eq $video.BaseName
                    }
                )
                videos = @($video)
            }
        }

        foreach ($group in $groups) {

            if (
                $group.images.Count -eq 0 -or
                $group.videos.Count -eq 0
            ) {
                continue
            }

            $entries = @(
                $Archive | Where-Object {
                    $_.cat -eq $cat -and
                    $_.title -eq $group.title
                }
            )

            if ($entries.Count -ne 1) {
                continue
            }

            $entry = $entries[0]

            $videoNames = @{}

            foreach ($video in $group.videos) {

                $hash = (
                    Get-FileHash `
                        -LiteralPath $video.FullName `
                        -Algorithm SHA256
                ).Hash.ToLower()

                $videoNames[$hash] = $video.BaseName
            }

            $changed = $false

            # Update each video poster

            foreach ($slide in @($entry.slides)) {

                if ($slide.type -ne 'video') {
                    continue
                }

                $hash = [string]$slide.hash

                if (!$videoNames.ContainsKey($hash)) {
                    continue
                }

                $name = $videoNames[$hash]

                $cover = Select-ReelCover `
                    -Images $group.images `
                    -VideoName $name

                if (!$cover) {
                    continue
                }

                $newImage = Convert-ReelCover $cover

                if ($slide.image -ne $newImage) {

                    $slide.image = $newImage
                    $changed = $true
                }
            }

            # Use first reel poster as group cover

            if (@($entry.slides).Count -gt 0) {

                $firstCover = $entry.slides[0].image

                if ($firstCover -and $entry.img -ne $firstCover) {

                    $entry.img = $firstCover
                    $changed = $true
                }
            }

            if ($changed) {

                $updated++

                Write-Host (
                    "COVER UPDATED : " + $group.title
                ) -ForegroundColor Green

            } else {

                Write-Host (
                    "COVER KEEP : " + $group.title
                ) -ForegroundColor DarkGray
            }
        }
    }

    Write-Host "UPDATED REEL COVERS : $updated" `
        -ForegroundColor Green
}

# =========================================
# 02. PSD SOURCE CLEANUP
# =========================================

function Move-SNSDesignSources {

    $root = (Get-Location).Path

    $backupRoot = Join-Path `
        (Split-Path $root -Parent) `
        'portfolio-backups/psd-originals'

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $moved = 0

    foreach ($folder in @(
        '피드게시물용',
        '릴스용'
    )) {

        if (!(Test-Path -LiteralPath $folder)) {
            continue
        }

        $files = @(
            Get-ChildItem `
                -LiteralPath $folder `
                -File -Recurse |
            Where-Object {
                $_.Extension -match '^\.(psd|psb)$'
            }
        )

        foreach ($file in $files) {

            $relative = $file.FullName.Substring(
                $root.Length+1
            )

            $destination = Join-Path `
                (Join-Path $backupRoot $stamp) `
                $relative

            $parent = Split-Path $destination -Parent

            try {

                New-Item -ItemType Directory `
                    -Path $parent -Force | Out-Null

                if (Test-Path -LiteralPath $destination) {
                    throw "Backup destination already exists."
                }

                Move-Item `
                    -LiteralPath $file.FullName `
                    -Destination $destination

                $moved++

                Write-Host (
                    "PSD ARCHIVED : " + $relative
                ) -ForegroundColor Yellow

            } catch {

                Write-Warning (
                    "PSD preserved: " + $file.FullName +
                    " / " + $_.Exception.Message
                )
            }
        }
    }

    Write-Host "PSD / PSB ARCHIVED : $moved"

    if ($moved -gt 0) {
        Write-Host "PSD BACKUP : $backupRoot"
    }
}