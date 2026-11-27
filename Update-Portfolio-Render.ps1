# V31.1.2 - SAFE PROMOTION RENDERER

$ErrorActionPreference = 'Stop'

Set-Location -LiteralPath $PSScriptRoot

$root = (Get-Location).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)

$base = 'assets/other/portfolio-auto'

$htmlPath = Join-Path $root 'index.html'

$originalPath = "$base/promotion-original.json"
$manifestPath = "$base/manifest.json"

$original = ConvertFrom-Json -InputObject (
    [IO.File]::ReadAllText(
        (Join-Path $root $originalPath)
    )
)

$manifest = ConvertFrom-Json -InputObject (
    [IO.File]::ReadAllText(
        (Join-Path $root $manifestPath)
    )
)

$campaigns = New-Object System.Collections.ArrayList

foreach ($item in $original) {

    if (
        !$item.PSObject.Properties['id'] -or
        !$item.PSObject.Properties['brand']
    ) {
        throw "Invalid original campaign."
    }

    [void]$campaigns.Add($item)
}

if ($campaigns.Count -ne 12) {

    throw "Original campaign count mismatch."
}

$ffprobe = Get-Command ffprobe `
    -ErrorAction SilentlyContinue

function Get-ImageRatio([string]$path) {

    if (!$ffprobe) {
        return 0
    }

    try {

        $result = @(
            & $ffprobe.Source `
                -v error `
                -select_streams 'v:0' `
                -show_entries 'stream=width,height' `
                -of 'csv=p=0:s=x' `
                $path 2>$null
        )

        if (
            $result.Count -gt 0 -and
            $result[0] -match '^(\d+)x(\d+)$'
        ) {

            $w = [double]$Matches[1]
            $h = [double]$Matches[2]

            if ($h -gt 0) {
                return ($w/$h)
            }
        }

    } catch {}

    return 0
}

$generatedCount = 0
$mediaCount = 0

foreach ($project in @($manifest.items)) {

    if (
        !$project -or
        $project.section -ne 'promo'
    ) {
        continue
    }

    $brand = switch ($project.category) {

        '자영이꺼' { 'jy' }
        '이룸디자인스킨' { 'ds' }
        default { '' }
    }

    if (!$brand) {
        continue
    }

    $items = New-Object System.Collections.ArrayList
    $coverCandidates = @()

    foreach ($media in @($project.media)) {

        if ($media.type -ne 'image') {
            continue
        }

        $src = [string]$media.image

        if (
            !$src -or
            !(Test-Path -LiteralPath $src -PathType Leaf)
        ) {
            throw "Missing media: $src"
        }

        $ratio = Get-ImageRatio $src

        $isLong = (
            $media.role -eq '기획전' -or
            ($ratio -gt 0 -and $ratio -lt 0.38)
        )

        $label = if ($isLong) {

            'EVENT PAGE'

        } elseif ($media.role -eq 'GDN') {

            'AD CREATIVE'

        } else {

            'WEB BANNER'
        }

        [void]$items.Add(
            [PSCustomObject]@{
                image = $src
                href  = $src
                label = $label
            }
        )

        $score = 0

        if (!$isLong) {
            $score += 100
        }

        if ($media.role -eq '메인배너') {
            $score += 20
        }

        if ($ratio -gt 0) {

            $score -= [math]::Abs(
                [math]::Log($ratio/0.75)
            ) * 20
        }

        $coverCandidates += [PSCustomObject]@{
            image = $src
            score = $score
        }

        $mediaCount++
    }

    if ($items.Count -eq 0) {
        continue
    }

    $cover = $coverCandidates |
        Sort-Object score -Descending |
        Select-Object -First 1

    $sha = [Security.Cryptography.SHA256]::Create()

    try {

        $bytes = [Text.Encoding]::UTF8.GetBytes(
            [string]$project.id
        )

        $hash = [BitConverter]::ToString(
            $sha.ComputeHash($bytes)
        ).Replace('-','').ToLower()

    } finally {

        $sha.Dispose()
    }

    [void]$campaigns.Add(
        [PSCustomObject]@{
            id = 'auto-v311-' + $hash.Substring(0,20)
            brand = $brand
            title = [string]$project.title
            cover = $cover.image
            items = @($items.ToArray())
        }
    )

    $generatedCount++

    Write-Host (
        "ADD : " + $project.title +
        " / " + $items.Count + " images"
    ) -ForegroundColor Green
}

# =========================================
# VERIFY FLAT ARRAY AND COUNTS
# =========================================

$final = $campaigns.ToArray()

$expected = 12 + $generatedCount

if ($final.Count -ne $expected) {

    throw "Campaign count mismatch. HTML unchanged."
}

$json = ConvertTo-Json `
    -InputObject $final `
    -Depth 30 -Compress

$roundtrip = ConvertFrom-Json -InputObject $json

$verified = 0

foreach ($item in $roundtrip) {

    if (
        $item -is [array] -or
        !$item.PSObject.Properties['id'] -or
        !$item.PSObject.Properties['brand']
    ) {
        throw "Invalid nested campaign. HTML unchanged."
    }

    $verified++
}

if ($verified -ne $expected) {

    throw "JSON validation failed. HTML unchanged."
}

$jy = @(
    $final |
    Where-Object { $_.brand -eq 'jy' }
).Count

$ds = @(
    $final |
    Where-Object { $_.brand -eq 'ds' }
).Count

if ($jy -lt 5 -or $ds -lt 7) {

    throw "Original campaigns missing. HTML unchanged."
}

$json = $json.Replace('<','\u003c')
$json = $json.Replace('>','\u003e')
$json = $json.Replace('&','\u0026')
$json = $json.Replace(
    [string][char]0x2028,'\u2028'
)
$json = $json.Replace(
    [string][char]0x2029,'\u2029'
)

# =========================================
# REPLACE ONLY PROMOTION DATA
# =========================================

$html = [IO.File]::ReadAllText($htmlPath)

$pattern = '(?is)<script\b[^>]*\bid="v30162a-promo-script"[^>]*>.*?</script>'

$blocks = [regex]::Matches(
    $html,$pattern
)

if ($blocks.Count -ne 1) {

    throw "Promotion script not found."
}

$block = $blocks[0]

$dataPattern = '(?m)^[ \t]*const campaigns = (\[.*\]);[ \t]*\r?$'

$dataBlocks = [regex]::Matches(
    $block.Value,$dataPattern
)

if ($dataBlocks.Count -ne 1) {

    throw "Promotion data block not found."
}

$data = $dataBlocks[0]

$newBlock = $block.Value.Remove(
    $data.Index,$data.Length
).Insert(
    $data.Index,
    '    const campaigns = ' + $json + ';'
)

$newHTML = $html.Remove(
    $block.Index,$block.Length
).Insert(
    $block.Index,$newBlock
)

$backupDir = Join-Path `
    (Split-Path $root -Parent) `
    'portfolio-backups'

New-Item -ItemType Directory `
    -Path $backupDir -Force | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'

if ($newHTML -cne $html) {

    Copy-Item -LiteralPath $htmlPath `
        -Destination (
            Join-Path $backupDir `
                "index-before-v3112-$stamp.html"
        )

    [IO.File]::WriteAllText(
        $htmlPath,
        $newHTML,
        $utf8
    )
}

Write-Host ""
Write-Host "====================================" -ForegroundColor Green
Write-Host " V31.1.2 PROMOTION REPAIR COMPLETE" -ForegroundColor Green
Write-Host "====================================" -ForegroundColor Green
Write-Host "ORIGINAL CAMPAIGNS : 12"
Write-Host "NEW CAMPAIGNS      : $generatedCount"
Write-Host "NEW IMAGES         : $mediaCount"
Write-Host "JAYEONGIKKEO       : $jy"
Write-Host "DESIGNSKIN         : $ds"
Write-Host "TOTAL CAMPAIGNS    : $($final.Count)"
Write-Host "JSON STRUCTURE     : VERIFIED"
Write-Host "SNS DATA           : UNCHANGED"

if (!$ffprobe) {

    Write-Warning "FFprobe missing. Cover selection uses folder labels only."
}