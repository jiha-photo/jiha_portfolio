# V30.18.2 - ONE CLICK SNS UPDATER

$ErrorActionPreference = 'Stop'

Set-Location -LiteralPath $PSScriptRoot

$root = (Get-Location).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)

$base = 'assets/other/designskin-sns'
$manifestPath = Join-Path $root "$base/manifest.json"
$htmlPath = Join-Path $root 'index.html'

$started = Get-Date

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " V30.18.2 - ONE CLICK SNS UPDATER" -ForegroundColor Cyan
Write-Host " DESIGNSKIN PORTFOLIO ARCHIVE"
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

try {

    # ========================================
    # 01. PREFLIGHT
    # ========================================

    if (!(Test-Path -LiteralPath $htmlPath)) {
        throw "index.html not found."
    }

    if (!(Test-Path -LiteralPath $manifestPath)) {
        throw "Existing manifest not found."
    }

    $oldHTML = [IO.File]::ReadAllText($htmlPath)
    $oldJSON = [IO.File]::ReadAllText($manifestPath)

    $manifest = ConvertFrom-Json -InputObject $oldJSON

    $patchPattern = '(?is)<script\b[^>]*\bid="v30181-designskin-script"[^>]*>.*?</script>'

    $patchMatches = [regex]::Matches(
        $oldHTML,$patchPattern
    )

    if ($patchMatches.Count -ne 1) {
        throw "Expected exactly one V30.18.1 SNS patch."
    }

    $patch = $patchMatches[0]

    $dataPattern = '(?m)^[ \t]*const DATA = (.+);[ \t]*\r?$'

    $dataMatches = [regex]::Matches(
        $patch.Value,$dataPattern
    )

    if ($dataMatches.Count -ne 1) {
        throw "SNS data block not found."
    }

    $oldPayload = ConvertFrom-Json `
        -InputObject $dataMatches[0].Groups[1].Value

    $feedRoot = '피드게시물용'
    $reelRoot = '릴스용'

    $hasFeed = Test-Path -LiteralPath $feedRoot -PathType Container
    $hasReel = Test-Path -LiteralPath $reelRoot -PathType Container

    if (!$hasFeed -and !$hasReel) {
        throw "No local source folders. Existing website preserved."
    }

    if (!$hasFeed) {
        Write-Warning "Feed source folder missing. Existing posts preserved."
    }

    if (!$hasReel) {
        Write-Warning "Reel source folder missing. Existing reels preserved."
    }

    $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue

    if (!$ffmpeg) {
        throw "FFmpeg not found. Install FFmpeg or add it to PATH."
    }

    $ff = $ffmpeg.Source

    $categories = @{
        'own'        = 'own'
        '자사'        = 'own'
        '디즈니'      = 'disney'
        'DISNEY'     = 'disney'
        '네이버웹툰'  = 'webtoon'
        'WEBTOON'    = 'webtoon'
        '이랜드'      = 'eland'
        'E-LAND'     = 'eland'
        'E·LAND'     = 'eland'
        'K리그'       = 'kleague'
        'K LEAGUE'   = 'kleague'
        'OTHER IP'   = 'ipcollab'
        '인플루언서'  = 'inf'
        'INFLUENCER' = 'inf'
    }

    $labels = [ordered]@{
        own      = 'OWN'
        disney   = 'DISNEY'
        webtoon  = 'WEBTOON'
        eland    = 'E·LAND'
        kleague  = 'K LEAGUE'
        ipcollab = 'OTHER IP'
        inf      = 'INFLUENCER'
    }

    $imagePattern = '^\.(jpg|jpeg|png|webp|bmp|tif|tiff|heic|avif)$'
    $videoPattern = '^\.(mp4|mov|m4v|webm|avi|mkv)$'

    foreach ($dir in @(
        "$base/web/feed",
        "$base/web/reels",
        "$base/thumbnails"
    )) {
        New-Item -ItemType Directory `
            -Path $dir -Force | Out-Null
    }

    function Natural-Key([string]$name) {

        return [regex]::Replace(
            $name,
            '\d+',
            {
                param($m)
                $m.Value.PadLeft(20,'0')
            }
        )
    }

    function Test-Output([string]$file) {

        if ([string]::IsNullOrWhiteSpace($file)) {
            return $false
        }

        return (
            (Test-Path -LiteralPath $file -PathType Leaf) -and
            ((Get-Item -LiteralPath $file).Length -gt 0)
        )
    }

    # ========================================
    # 02. PRESERVE EXISTING ARCHIVE
    # ========================================

    $posts = New-Object System.Collections.ArrayList
    $reels = New-Object System.Collections.ArrayList

    foreach ($p in @($manifest.posts)) {

        if ($null -ne $p) {
            [void]$posts.Add($p)
        }
    }

    foreach ($r in @($manifest.reels)) {

        if ($null -ne $r) {
            [void]$reels.Add($r)
        }
    }

    $oldPostCount = $posts.Count
    $oldReelCount = $reels.Count

    $converted = 0
    $cacheHits = 0
    $addedSlides = 0
    $newGroups = 0
    $updatedGroups = 0
    $duplicateCount = 0

    $failures = @()
    $skipped = @()
    $changes = @()

    Write-Host "EXISTING FEED : $oldPostCount"
    Write-Host "EXISTING REEL : $oldReelCount"

    # ========================================
    # 03. SCAN AND PROCESS SOURCES
    # ========================================

    foreach ($mode in @('feed','reel')) {

        $sourceRoot = if ($mode -eq 'feed') {
            $feedRoot
        } else {
            $reelRoot
        }

        if (!(Test-Path -LiteralPath $sourceRoot -PathType Container)) {
            continue
        }

        Write-Host "`n=== SCAN $mode ===" -ForegroundColor Cyan

        $archive = if ($mode -eq 'feed') {
            $posts
        } else {
            $reels
        }

        # Avoid PowerShell array unrolling

        if ($mode -eq 'feed') {
            $archive = $posts
        } else {
            $archive = $reels
        }

        $categoryFolders = @(
            Get-ChildItem `
                -LiteralPath $sourceRoot `
                -Directory |
            Sort-Object Name
        )

        foreach ($category in $categoryFolders) {

            if ($category.Name -match '^(공구|GROUP BUY)$') {
                continue
            }

            if (!$categories.ContainsKey($category.Name)) {

                $skipped += $category.FullName

                Write-Warning "Unknown category: $($category.Name)"

                continue
            }

            $cat = $categories[$category.Name]

            Write-Host "`n[$($labels[$cat])]" -ForegroundColor Yellow

            $groups = @()

            foreach ($folder in @(
                Get-ChildItem `
                    -LiteralPath $category.FullName `
                    -Directory |
                Sort-Object {
                    Natural-Key $_.Name
                }
            )) {

                $groups += [PSCustomObject]@{
                    title = $folder.Name
                    files = @(
                        Get-ChildItem `
                            -LiteralPath $folder.FullName `
                            -File -Recurse |
                        Sort-Object {
                            Natural-Key $_.FullName
                        }
                    )
                }
            }

            foreach ($file in @(
                Get-ChildItem `
                    -LiteralPath $category.FullName `
                    -File |
                Sort-Object {
                    Natural-Key $_.Name
                }
            )) {

                $groups += [PSCustomObject]@{
                    title = $file.BaseName
                    files = @($file)
                }
            }

            foreach ($group in $groups) {

                $matches = @(
                    $archive |
                    Where-Object {
                        $_.cat -eq $cat -and
                        $_.title -eq $group.title
                    }
                )

                if ($matches.Count -gt 1) {

                    throw "Duplicate group name: $cat / $($group.title)"
                }

                $old = $null

                if ($matches.Count -eq 1) {
                    $old = $matches[0]
                }

                $slides = New-Object System.Collections.ArrayList
                $seen = @{}
                $groupAdded = 0

                # Preserve existing slides even if
                # originals are absent on this PC.

                if ($old) {

                    foreach ($slide in @($old.slides)) {

                        if ($null -eq $slide) {
                            continue
                        }

                        [void]$slides.Add($slide)

                        if ($slide.hash) {
                            $seen[[string]$slide.hash] = $true
                        }
                    }
                }

                foreach ($file in $group.files) {

                    $isImage = $file.Extension -match $imagePattern
                    $isVideo = $file.Extension -match $videoPattern

                    if (
                        ($mode -eq 'feed' -and !$isImage) -or
                        ($mode -eq 'reel' -and !$isVideo)
                    ) {
                        continue
                    }

                    $hash = (
                        Get-FileHash `
                            -LiteralPath $file.FullName `
                            -Algorithm SHA256
                    ).Hash.ToLower()

                    if ($seen.ContainsKey($hash)) {

                        $duplicateCount++

                        continue
                    }

                    $key = $hash.Substring(0,32)

                    # ========================
                    # IMAGE
                    # ========================

                    if ($mode -eq 'feed') {

                        $out = "$base/web/feed/$key.webp"

                        if (!(Test-Output $out)) {

                            $tmp = "$base/web/feed/$key.tmp.webp"

                            Write-Host "IMAGE : $($file.Name)"

                            & $ff -hide_banner -loglevel error -y `
                                -i $file.FullName `
                                -map '0:v:0' `
                                -vf "scale=w='min(iw,1920)':h='min(ih,1920)':force_original_aspect_ratio=decrease" `
                                -frames:v 1 `
                                -c:v libwebp `
                                -quality 92 `
                                -compression_level 6 `
                                $tmp

                            if (
                                $LASTEXITCODE -ne 0 -or
                                !(Test-Output $tmp)
                            ) {

                                $failures += $file.FullName

                                if (Test-Path -LiteralPath $tmp) {
                                    Remove-Item -LiteralPath $tmp
                                }

                                continue
                            }

                            Move-Item -LiteralPath $tmp `
                                -Destination $out -Force

                            $converted++

                        } else {

                            $cacheHits++
                        }

                        $entry = [PSCustomObject]@{
                            type  = 'image'
                            image = $out
                            hash  = $hash
                        }

                    } else {

                        # ====================
                        # VIDEO
                        # ====================

                        $out = "$base/web/reels/$key.mp4"
                        $thumb = "$base/thumbnails/$key.webp"

                        $needsVideo = !(Test-Output $out)

                        if (!$needsVideo) {

                            $needsVideo = (
                                (Get-Item -LiteralPath $out).Length -ge 95MB
                            )
                        }

                        if ($needsVideo) {

                            $tmp = "$base/web/reels/$key.tmp.mp4"
                            $success = $false

                            Write-Host "VIDEO : $($file.Name)"

                            foreach ($crf in @(21,24,27,30)) {

                                & $ff -hide_banner -loglevel error -y `
                                    -i $file.FullName `
                                    -map '0:v:0' `
                                    -map '0:a?' `
                                    -vf "scale=w='min(iw,1080)':h='min(ih,1920)':force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1" `
                                    -c:v libx264 `
                                    -preset medium `
                                    -crf $crf `
                                    -pix_fmt yuv420p `
                                    -c:a aac `
                                    -b:a 128k `
                                    -movflags +faststart `
                                    $tmp

                                if (
                                    $LASTEXITCODE -eq 0 -and
                                    (Test-Output $tmp) -and
                                    ((Get-Item -LiteralPath $tmp).Length -lt 95MB)
                                ) {

                                    $success = $true
                                    break
                                }
                            }

                            if (!$success) {

                                $failures += $file.FullName

                                if (Test-Path -LiteralPath $tmp) {
                                    Remove-Item -LiteralPath $tmp
                                }

                                continue
                            }

                            Move-Item -LiteralPath $tmp `
                                -Destination $out -Force

                            $converted++

                        } else {

                            $cacheHits++
                        }

                        # Thumbnail

                        if (!(Test-Output $thumb)) {

                            $tmpThumb = "$base/thumbnails/$key.tmp.webp"

                            & $ff -hide_banner -loglevel error -y `
                                -i $out `
                                -frames:v 1 `
                                -vf "scale=w='min(iw,720)':h='min(ih,960)':force_original_aspect_ratio=decrease" `
                                -c:v libwebp `
                                -quality 90 `
                                $tmpThumb

                            if (
                                $LASTEXITCODE -ne 0 -or
                                !(Test-Output $tmpThumb)
                            ) {

                                $failures += "$($file.FullName) - thumbnail"

                                if (Test-Path -LiteralPath $tmpThumb) {
                                    Remove-Item -LiteralPath $tmpThumb
                                }

                                continue
                            }

                            Move-Item -LiteralPath $tmpThumb `
                                -Destination $thumb -Force
                        }

                        $entry = [PSCustomObject]@{
                            type  = 'video'
                            image = $thumb
                            video = $out
                            hash  = $hash
                        }
                    }

                    [void]$slides.Add($entry)

                    $seen[$hash] = $true
                    $addedSlides++
                    $groupAdded++
                }

                if ($groupAdded -eq 0) {

                    if ($old) {

                        Write-Host "KEEP : $($group.title)" `
                            -ForegroundColor DarkGray
                    }

                    continue
                }

                # ============================
                # MERGE CONTENT GROUP
                # ============================

                $newEntry = [PSCustomObject]@{
                    cat      = $cat
                    category = $labels[$cat]
                    title    = $group.title
                    cap      = $group.title
                    img      = $slides[0].image
                    video    = $slides[0].video
                    count    = $slides.Count
                    carousel = ($slides.Count -gt 1)
                    slides   = @($slides.ToArray())
                    likes    = '—'
                    views    = '—'
                }

                if ($old) {

                    $index = $archive.IndexOf($old)

                    $archive[$index] = $newEntry

                    $updatedGroups++

                    $changes += "UPDATE | $mode | $cat | $($group.title) | +$groupAdded"

                    Write-Host "UPDATED : $($group.title) +$groupAdded" `
                        -ForegroundColor Green

                } else {

                    # Put newly created groups first

                    $archive.Insert(0,$newEntry)

                    $newGroups++

                    $changes += "NEW | $mode | $cat | $($group.title) | $groupAdded"

                    Write-Host "NEW : $($group.title) ($groupAdded)" `
                        -ForegroundColor Green
                }
            }
        }
    }

    # ========================================
    # 04. VALIDATE ALL ARCHIVE MEDIA
    # ========================================

    if ($failures.Count -gt 0) {

        $failures | ForEach-Object {
            Write-Host $_ -ForegroundColor Red
        }

        throw "Conversion failures. HTML and manifest unchanged."
    }

    $missing = @()
    $allSlides = @()

    foreach ($group in @(
        $posts.ToArray() + $reels.ToArray()
    )) {

        foreach ($slide in @($group.slides)) {

            $allSlides += $slide

            foreach ($p in @($slide.image,$slide.video)) {

                if ([string]::IsNullOrWhiteSpace($p)) {
                    continue
                }

                $decoded = [Uri]::UnescapeDataString($p)

                if (!(Test-Output $decoded)) {

                    $missing += $p
                    continue
                }

                if (
                    (Get-Item -LiteralPath $decoded).Length -ge 95MB
                ) {

                    $missing += "OVERSIZE: $p"
                }
            }
        }
    }

    if ($missing.Count -gt 0) {

        $missing | Sort-Object -Unique |
            ForEach-Object {
                Write-Host $_ -ForegroundColor Red
            }

        throw "Archive validation failed. Pull missing web assets first."
    }

    Write-Host "`nALL ARCHIVE MEDIA VALIDATED" -ForegroundColor Green

    # ========================================
    # 05. CHECK LEGACY DUPLICATES
    # ========================================

    $hashes = @{}

    foreach ($slide in $allSlides) {

        if ($slide.hash) {
            $hashes[[string]$slide.hash] = $true
        }
    }

    $duplicatePaths = @(
        $oldPayload.duplicatePaths |
        Where-Object { $_ }
    )

    foreach ($folder in @(
        'assets/other/own-feed',
        'assets/other/own-reels',
        'assets/other/ip-reels'
    )) {

        if (!(Test-Path -LiteralPath $folder)) {
            continue
        }

        foreach ($file in @(
            Get-ChildItem `
                -LiteralPath $folder `
                -File -Recurse |
            Where-Object {
                $_.Extension -match '^\.(jpg|jpeg|png|webp|mp4|mov|webm)$'
            }
        )) {

            $hash = (
                Get-FileHash `
                    -LiteralPath $file.FullName `
                    -Algorithm SHA256
            ).Hash.ToLower()

            if ($hashes.ContainsKey($hash)) {

                $duplicatePaths += $file.FullName.Substring(
                    $root.Length+1
                ).Replace('\','/')
            }
        }
    }

    $duplicatePaths = @(
        $duplicatePaths | Sort-Object -Unique
    )

    # Preserve previously registered paths

    $localAssets = @(
        $oldPayload.localAssets |
        Where-Object { $_ }
    )

    foreach ($folder in @('assets','images','videos')) {

        if (!(Test-Path -LiteralPath $folder)) {
            continue
        }

        $localAssets += @(
            Get-ChildItem `
                -LiteralPath $folder `
                -File -Recurse |
            Where-Object {
                $_.Extension -match '^\.(jpg|jpeg|png|webp|gif|avif|mp4|mov|webm|m4v)$'
            } |
            ForEach-Object {
                $_.FullName.Substring(
                    $root.Length+1
                ).Replace('\','/')
            }
        )
    }

    $localAssets = @(
        $localAssets | Sort-Object -Unique
    )

    # ========================================
    # 06. BUILD UPDATED MANIFEST
    # ========================================

    $newManifest = [ordered]@{
        version    = 'V30.18.2'
        brand      = 'DESIGNSKIN'
        account    = 'designskin'
        feedCount  = $posts.Count
        reelCount  = $reels.Count

        categories = @(
            foreach ($id in $labels.Keys) {

                @{
                    id   = $id
                    name = $labels[$id]
                }
            }
        )

        posts = @($posts.ToArray())
        reels = @($reels.ToArray())
    }

    $newJSON = ConvertTo-Json `
        -InputObject $newManifest `
        -Depth 20

    # ========================================
    # 07. UPDATE ONLY EMBEDDED SNS DATA
    # ========================================

    $payload = [ordered]@{
        posts          = @($posts.ToArray())
        reels          = @($reels.ToArray())
        categories     = @($newManifest.categories)
        localAssets    = @($localAssets)
        duplicatePaths = @($duplicatePaths)
    }

    $json = ConvertTo-Json `
        -InputObject $payload `
        -Depth 20 -Compress

    $json = $json.Replace('<','\u003c')
    $json = $json.Replace('>','\u003e')
    $json = $json.Replace('&','\u0026')
    $json = $json.Replace(
        [string][char]0x2028,'\u2028'
    )
    $json = $json.Replace(
        [string][char]0x2029,'\u2029'
    )

    $dataMatch = $dataMatches[0]

    $newPatch = $patch.Value.Remove(
        $dataMatch.Index,
        $dataMatch.Length
    ).Insert(
        $dataMatch.Index,
        '    const DATA = ' + $json + ';'
    )

    $newHTML = $oldHTML.Remove(
        $patch.Index,
        $patch.Length
    ).Insert(
        $patch.Index,
        $newPatch
    )

    # ========================================
    # 08. PROTECT SOURCE FOLDERS
    # ========================================

    $ignorePath = Join-Path $root '.gitignore'

    $ignore = if (
        Test-Path -LiteralPath $ignorePath
    ) {

        [IO.File]::ReadAllText($ignorePath)

    } else {

        ''
    }

    foreach ($rule in @(
        '/피드게시물용/',
        '/릴스용/'
    )) {

        if (($ignore -split '\r?\n') -notcontains $rule) {

            $ignore += "`r`n$rule`r`n"
        }
    }

    # Never remove tracked files automatically

    $git = Get-Command git -ErrorAction SilentlyContinue

    if ($git) {

        $tracked = @(
            & git ls-files -- '피드게시물용' '릴스용'
        )

        if ($tracked.Count -gt 0) {

            Write-Warning "Some original files are already tracked by Git."

            Write-Warning "Review GitHub Desktop before committing."
        }
    }

    # ========================================
    # 09. BACKUP AND SAVE
    # ========================================

    $backupDir = Join-Path `
        (Split-Path $root -Parent) `
        'portfolio-backups'

    New-Item -ItemType Directory `
        -Path $backupDir -Force | Out-Null

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'

    $htmlBackup = Join-Path `
        $backupDir `
        "index-before-v30182-$stamp.html"

    $manifestBackup = Join-Path `
        $backupDir `
        "manifest-before-v30182-$stamp.json"

    $dataChanged = (
        $newHTML -cne $oldHTML -or
        $newJSON -cne $oldJSON
    )

    if ($dataChanged) {

        Copy-Item `
            -LiteralPath $htmlPath `
            -Destination $htmlBackup

        Copy-Item `
            -LiteralPath $manifestPath `
            -Destination $manifestBackup

        try {

            [IO.File]::WriteAllText(
                $manifestPath,$newJSON,$utf8
            )

            [IO.File]::WriteAllText(
                $htmlPath,$newHTML,$utf8
            )

        } catch {

            Copy-Item `
                -LiteralPath $htmlBackup `
                -Destination $htmlPath -Force

            Copy-Item `
                -LiteralPath $manifestBackup `
                -Destination $manifestPath -Force

            throw "Save failed. Previous files restored."
        }
    }

    [IO.File]::WriteAllText(
        $ignorePath,$ignore,$utf8
    )

    if (!(Test-Path -LiteralPath '.nojekyll')) {

        New-Item `
            -ItemType File `
            -Path '.nojekyll' | Out-Null
    }

    # ========================================
    # 10. GENERATE UPDATE REPORT
    # ========================================

    $photoCount = (
        $posts | Measure-Object count -Sum
    ).Sum

    $videoCount = (
        $reels | Measure-Object count -Sum
    ).Sum

    $report = @(
        '=== V30.18.2 ONE CLICK SNS UPDATER ==='
        ''
        "DATE : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ''
        "PREVIOUS FEED GROUPS : $oldPostCount"
        "PREVIOUS REEL GROUPS : $oldReelCount"
        "TOTAL FEED GROUPS    : $($posts.Count)"
        "TOTAL REEL GROUPS    : $($reels.Count)"
        "TOTAL IMAGES        : $photoCount"
        "TOTAL VIDEOS        : $videoCount"
        ''
        "NEW GROUPS          : $newGroups"
        "UPDATED GROUPS      : $updatedGroups"
        "ADDED MEDIA         : $addedSlides"
        "NEW CONVERSIONS     : $converted"
        "CACHE REUSED        : $cacheHits"
        "EXISTING HASHES     : $duplicateCount"
        "LEGACY DUPLICATES   : $($duplicatePaths.Count)"
        "FAILURES            : 0"
        ''
    )

    foreach ($id in $labels.Keys) {

        $p = @(
            $posts | Where-Object {
                $_.cat -eq $id
            }
        )

        $r = @(
            $reels | Where-Object {
                $_.cat -eq $id
            }
        )

        $report += "=== $($labels[$id]) ==="
        $report += "POSTS : $($p.Count)"
        $report += "REELS : $($r.Count)"

        foreach ($item in $p) {

            $report += "FEED | $($item.title) | $($item.count)"
        }

        foreach ($item in $r) {

            $report += "REEL | $($item.title) | $($item.count)"
        }

        $report += ''
    }

    $report += '=== CHANGES ==='

    if ($changes.Count -eq 0) {

        $report += 'No new media found.'

    } else {

        $report += $changes
    }

    if ($skipped.Count -gt 0) {

        $report += ''
        $report += '=== UNKNOWN CATEGORIES ==='
        $report += $skipped
    }

    $report += ''
    $report += 'ORIGINALS : Preserved'
    $report += 'MAGAZINE : Preserved'
    $report += 'OTHER PROJECTS : Unchanged'
    $report += 'GIT PUSH : Manual'

    if ($dataChanged) {

        $report += "HTML BACKUP : $htmlBackup"
        $report += "MANIFEST BACKUP : $manifestBackup"

    } else {

        $report += 'HTML AND MANIFEST : No changes'
    }

    $report += "ELAPSED : $([math]::Round(((Get-Date)-$started).TotalSeconds,1)) seconds"

    $reportPath = Join-Path `
        $backupDir `
        "sns-update-report-$stamp.txt"

    [IO.File]::WriteAllLines(
        $reportPath,
        [string[]]$report,
        $utf8
    )

    # ========================================
    # 11. COMPLETE
    # ========================================

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host " V30.18.2 SNS UPDATE COMPLETE" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green

    Write-Host "FEED GROUPS    : $($posts.Count)"
    Write-Host "REEL GROUPS    : $($reels.Count)"
    Write-Host "TOTAL IMAGES   : $photoCount"
    Write-Host "TOTAL VIDEOS   : $videoCount"
    Write-Host "NEW GROUPS     : $newGroups"
    Write-Host "UPDATED GROUPS : $updatedGroups"
    Write-Host "ADDED MEDIA    : $addedSlides"
    Write-Host "CONVERTED      : $converted"
    Write-Host "FAILURES       : 0"
    Write-Host "REPORT         : $reportPath"
    Write-Host ""

    if ($skipped.Count -gt 0) {

        Write-Warning "Review skipped category folders in the report."
    }

    Write-Host "Review local website before GitHub Push." `
        -ForegroundColor Yellow

    notepad.exe $reportPath

    Start-Process $htmlPath

    exit 0

} catch {

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Red
    Write-Host " SNS UPDATE STOPPED" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red

    Write-Host $_.Exception.Message -ForegroundColor Red

    Write-Host ""
    Write-Host "Check the error before committing."

    exit 1
}