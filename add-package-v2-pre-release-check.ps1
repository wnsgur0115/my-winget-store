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

# === 메인 로직 시작 (에러 핸들링을 위해 Try-Catch로 감쌈) ===
try {
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
    
    # [수정됨] TrimEnd('.git') 버그 수정 -> -replace 사용
    # 기존 TrimEnd는 'vkdiag'의 'g'가 '.git'에 포함된 글자라 지워버리는 문제가 있었음
    $repoName = $matches[2].TrimEnd('/') -replace '\.git$', ''
    
    $fullRepo = "$owner/$repoName"

    # 2) package id 입력
    $suggestedId = "$owner.$repoName"
    Write-Host ""
    Write-Host "package id 입력 (엔터= $suggestedId)" -ForegroundColor Cyan
    $pkgId = Read-Host "id"
    if ([string]::IsNullOrWhiteSpace($pkgId)) { $pkgId = $suggestedId }

    Write-Host ""
    Write-Host "fetch latest release: $fullRepo" -ForegroundColor Yellow

    # 3) 최신 릴리스/자산 가져오기 (Stable 실패 시 Pre-release 탐색 및 확인 절차 포함)
    $latest = $null

    # 3-1. 우선 정식 latest 시도
    try {
        $latest = gh api "repos/$fullRepo/releases/latest" 2>$null | ConvertFrom-Json
    } catch {
        $latest = $null
    }

    # 3-2. 정식 latest가 없으면 전체 릴리스 목록에서 최신 1건(Pre-release 포함) 조회
    if (-not $latest) {
        Write-Host "NOTE: releases/latest(Stable)가 없음. 최신 릴리스(Pre-release 포함)를 찾습니다." -ForegroundColor DarkYellow
        
        # 릴리스 목록 중 가장 최신 1개만 가져옴
        $list = gh api "repos/$fullRepo/releases?per_page=1" 2>$null | ConvertFrom-Json
        
        if ($list -and $list.Count -gt 0) {
            $candidate = $list[0]
            $tagName = $candidate.tag_name
            $isPre = $candidate.prerelease
            
            Write-Host ""
            Write-Host ">> 발견된 버전: $tagName (Prerelease 여부: $isPre)" -ForegroundColor Magenta
            $confirm = Read-Host ">> 이 버전을 사용하려면 y 또는 엔터를 입력 (그 외 중단)"
            
            if ([string]::IsNullOrWhiteSpace($confirm) -or $confirm -match '^[yY]') {
                $latest = $candidate
            } else {
                throw "사용자가 Pre-release 사용을 거부함."
            }
        } else {
            throw "releases/latest도 없고, releases 목록도 비어있음."
        }
    }

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

    # 6) packages.yml 업데이트
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

} catch {
    # === 에러 발생 시 이곳으로 점프 ===
    Write-Host ""
    Write-Host "🛑 오류가 발생했습니다!" -BackgroundColor Red -ForegroundColor White
    Write-Host "----------------------------------------------------"
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "----------------------------------------------------"
    Write-Host "에러 상세 내용 (Stack Trace):" -ForegroundColor Gray
    Write-Host $_.ScriptStackTrace -ForegroundColor Gray
    Write-Host ""
    
    # 여기서 사용자 입력을 기다려서 창이 닫히지 않게 함
    Read-Host "확인하셨으면 엔터 키를 눌러 종료하세요..."
    exit 1
}