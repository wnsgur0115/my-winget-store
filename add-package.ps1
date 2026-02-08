<# :
@echo off
chcp 65001 > nul
title Add Package to packages.yml
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([System.IO.File]::ReadAllText('%~f0'))"
pause
goto :eof
#>

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Utf8NoBom {
    param([Parameter(Mandatory=$true)][string]$Path,
          [Parameter(Mandatory=$true)][string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Read-Text {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path $Path)) { return "" }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

Write-Host "=== winget package adder ===" -ForegroundColor Green
Write-Host ""

# 0) gh cli 체크
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "gh cli가 필요함. winget install GitHub.cli 로 설치해."
}

# 1) repo url 입력
Write-Host "repo url 입력 (예: https://github.com/Orbmu2k/nvidiaProfileInspector)" -ForegroundColor Cyan
$repoUrl = Read-Host "url"
if ([string]::IsNullOrWhiteSpace($repoUrl)) { throw "빈 입력" }

if ($repoUrl -notmatch 'github\.com/([^/]+)/([^/]+)') {
    throw "github repo url 형식이 아님"
}
$owner = $matches[1]
$repoName = $matches[2].TrimEnd('/').TrimEnd('.git')
$fullRepo = "$owner/$repoName"

# 2) package id 입력
$suggestedId = "$owner.$repoName"
Write-Host ""
Write-Host "package id 입력 (엔터= $suggestedId)" -ForegroundColor Cyan
$pkgId = Read-Host "id"
if ([string]::IsNullOrWhiteSpace($pkgId)) { $pkgId = $suggestedId }

Write-Host ""
Write-Host "fetch latest release: $fullRepo" -ForegroundColor Yellow

# 3) 최신 릴리스/자산 가져오기
$latest = gh api "repos/$fullRepo/releases/latest" | ConvertFrom-Json
if (-not $latest) { throw "releases/latest 없음 (릴리스가 없을 수도)" }

$assets = @($latest.assets)
if ($assets.Count -eq 0) {
    Write-Host "latest release에 assets가 없음. 브라우저로 열어줄게." -ForegroundColor Red
    Start-Process $latest.html_url
    exit 1
}

# 4) 자산 선택 ui (out-gridview 있으면 사용, 없으면 번호)
$selectedAsset = $null
if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
    $pick = $assets |
        Select-Object @{N='Name';E={$_.name}},
                      @{N='SizeMB';E={[math]::Round($_.size/1MB,2)}},
                      @{N='Url';E={$_.browser_download_url}} |
        Out-GridView -Title "select installer asset" -OutputMode Single

    if (-not $pick) { throw "선택 안 함" }
    $selectedAsset = $assets | Where-Object { $_.name -eq $pick.Name } | Select-Object -First 1
} else {
    for ($i=0; $i -lt $assets.Count; $i++) {
        "{0,3}. {1} ({2} MB)" -f ($i+1), $assets[$i].name, ([math]::Round($assets[$i].size/1MB,2)) | Write-Host
    }
    $n = Read-Host "번호 선택 (1-$($assets.Count))"
    if ($n -notmatch '^\d+$') { throw "숫자 아님" }
    $idx = [int]$n - 1
    if ($idx -lt 0 -or $idx -ge $assets.Count) { throw "범위 밖" }
    $selectedAsset = $assets[$idx]
}

$fileName = $selectedAsset.name
Write-Host ""
Write-Host "selected: $fileName" -ForegroundColor Green

# 5) asset_regex 자동 생성 (기본값)
$ext = [System.IO.Path]::GetExtension($fileName).ToLowerInvariant()

switch ($ext) {
    '.exe'  { $assetRegex = '\.exe$' }
    '.msi'  { $assetRegex = '\.msi$' }
    '.zip'  { $assetRegex = '\.zip$' }
    '.msix' { $assetRegex = '\.msix$' }
    default { $assetRegex = [regex]::Escape($fileName) + '$' }
}

Write-Host "auto asset_regex = $assetRegex" -ForegroundColor Gray
$custom = Read-Host "regex 바꾸려면 입력 (엔터=그대로)"
if (-not [string]::IsNullOrWhiteSpace($custom)) { $assetRegex = $custom }

# 6) packages.yml 업데이트 (여기서 -replace 절대 안 씀)
$path = Join-Path $PSScriptRoot "packages.yml"
$content = Read-Text $path

$entry = "  - id: $pkgId`n    repo: $fullRepo`n    asset_regex: '$assetRegex'`n"

if ([string]::IsNullOrWhiteSpace($content)) {
    $content = "packages:`n$entry"
}
elseif ($content -match '(?m)^\s*packages:\s*\[\s*\]\s*$') {
    # packages: [] 를 packages: + entry로 교체 (match evaluator라 $ 문법 안 터짐)
    $content = [regex]::Replace(
        $content,
        '(?m)^\s*packages:\s*\[\s*\]\s*$',
        { param($m) "packages:`n$entry" }
    )
}
elseif ($content -notmatch '(?m)^\s*packages:\s*$') {
    # packages: 헤더가 아예 없으면 맨 위에 추가
    $content = "packages:`n$entry`n" + $content.TrimStart()
}
else {
    # 그냥 append
    if (-not $content.EndsWith("`n")) { $content += "`n" }
    $content += $entry
}

Write-Utf8NoBom -Path $path -Text $content

Write-Host ""
Write-Host "✅ updated packages.yml" -ForegroundColor Green
Write-Host "----------------------------------------"
Get-Content $path
Write-Host "----------------------------------------"
Write-Host "next: setup.ps1 실행해서 manifests 만들고, git commit/push 해."
