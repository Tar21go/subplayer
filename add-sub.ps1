# 把字幕檔加進網站並上傳到 GitHub
# 用法：把 .srt / .vtt 檔拖到 add-sub.bat 上（可以一次拖好幾個）
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Files)

[Console]::OutputEncoding = [Text.Encoding]::UTF8
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$root = $PSScriptRoot
Set-Location -LiteralPath $root

if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
    Write-Host '這個資料夾不是 GitHub 下載下來的 repo，請把 add-sub.bat 和 add-sub.ps1 放進 clone 下來的資料夾裡。' -ForegroundColor Red
    exit 1
}

$subsDir = Join-Path $root 'subs'
if (-not (Test-Path -LiteralPath $subsDir)) { New-Item -ItemType Directory -Path $subsDir | Out-Null }

$jsonPath = Join-Path $root 'videos.json'
$utf8 = New-Object Text.UTF8Encoding($false)

function Get-VideoId([string]$s, [bool]$allowBare) {
    if ($s -match '(?:v=|youtu\.be/|shorts/|embed/|live/)([\w-]{11})') { return $Matches[1] }
    if ($s -match '\[([\w-]{11})\]') { return $Matches[1] }
    if ($allowBare -and $s.Trim() -match '^[\w-]{11}$') { return $s.Trim() }
    return $null
}

function Read-SubText([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { return [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2) }
    try {
        $t = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes)
        return $t.TrimStart([char]0xFEFF)
    } catch {
        # 不是 UTF-8，當成 Big5（繁中 Windows 常見）
        return [Text.Encoding]::GetEncoding(950).GetString($bytes)
    }
}

function Get-Title([string]$id) {
    try {
        $u = "https://www.youtube.com/oembed?format=json&url=https://www.youtube.com/watch?v=$id"
        $r = Invoke-WebRequest -UseBasicParsing -Uri $u -TimeoutSec 15
        $txt = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        return ($txt | ConvertFrom-Json).title
    } catch { return $null }
}

# 先同步一次，避免跟網頁上的修改衝突
git pull --rebase -q 2>$null

$list = @()
if (Test-Path -LiteralPath $jsonPath) {
    $raw = [IO.File]::ReadAllText($jsonPath, [Text.Encoding]::UTF8)
    if ($raw.Trim()) { $list = @($raw | ConvertFrom-Json) }
}

if (-not $Files -or $Files.Count -eq 0) {
    $p = Read-Host '把字幕檔拖進這個視窗，然後按 Enter'
    $Files = @($p)
}

$added = 0
foreach ($f in $Files) {
    $f = $f.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "找不到檔案：$f" -ForegroundColor Red; continue }

    $name = [IO.Path]::GetFileNameWithoutExtension($f)
    $ext = [IO.Path]::GetExtension($f).ToLower()
    if ($ext -ne '.vtt') { $ext = '.srt' }

    $id = Get-VideoId $name $false
    while (-not $id) {
        $u = Read-Host "「$name」是哪一部影片？貼上 YouTube 網址後按 Enter"
        $id = Get-VideoId $u $true
        if (-not $id) { Write-Host '看不懂這個網址，再試一次。' -ForegroundColor Yellow }
    }

    $title = Get-Title $id
    if (-not $title) { $title = $name }

    $dest = Join-Path $subsDir ($id + $ext)
    [IO.File]::WriteAllText($dest, (Read-SubText $f), $utf8)

    $item = [pscustomobject]@{ id = $id; title = $title; sub = "subs/$id$ext"; added = (Get-Date -Format 'yyyy-MM-dd') }
    $list = @($item) + @($list | Where-Object { $_.id -ne $id })
    Write-Host "✓ $title" -ForegroundColor Green
    $added++
}

if ($added -eq 0) { Write-Host '沒有加入任何字幕。'; exit 1 }

[IO.File]::WriteAllText($jsonPath, (ConvertTo-Json -InputObject @($list) -Depth 3), $utf8)

Write-Host '上傳到 GitHub 中…'
git add -A
git commit -q -m "add subtitles"
git push -q
if ($LASTEXITCODE -ne 0) {
    Write-Host '上傳失敗，請把這個視窗截圖給 Claude 看。' -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host '完成！大約 1 分鐘後手機重新整理網頁就看得到。' -ForegroundColor Green
