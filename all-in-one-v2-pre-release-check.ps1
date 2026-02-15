<#
.SYNOPSIS
    Winget 사용자 정의 저장소 통합 패키지 추가 도구 (v5.2 - Pre-release Logic Added)
.DESCRIPTION
    1. GitHub Repo URL 입력 및 중복 ID 체크 (Skip 로직 포함)
    2. packages.yml 무결성 보장 업데이트
    3. 릴리스 조회 실패 시 Pre-release 탐색 및 사용자 확인 절차 추가
    4. wingetcreate 분기 처리 (New vs Update)
    5. Git Pull(Rebase) -> Commit (Action 명시) -> Push
#>

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- [0] Helper Functions ---

function Write-Log {
    param([string]$Message, [string]$Color = "White", [string]$Level = "INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    switch ($Level) {
        "INFO"    { Write-Host "[$timestamp] $Message" -ForegroundColor $Color }
        "SUCCESS" { Write-Host "[$timestamp] ✅ $Message" -ForegroundColor Green }
        "WARN"    { Write-Host "[$timestamp] ⚠️ $Message" -ForegroundColor Yellow }
        "ERROR"   { Write-Host "[$timestamp] ❌ $Message" -ForegroundColor Red }
    }
}

function Assert-Command {
    param([string]$Name, [string]$InstallCmd)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Log "$Name 도구가 없습니다. 설치해주세요: $InstallCmd" -Level ERROR
        exit 2
    }
}

function Set-Utf8NoBomContent {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false) # No BOM
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

# --- [1] Environment Check ---
Write-Log "환경 및 도구 점검 중..." -Color Cyan
Assert-Command "gh" "winget install GitHub.cli"
Assert-Command "wingetcreate" "winget install Microsoft.WingetCreate"
Assert-Command "git" "winget install Git.Git"

if (-not (Test-Path ".git")) {
    Write-Log "현재 폴더가 Git 저장소가 아닙니다." -Level ERROR
    exit 1
}

$addedPackages = @()

# --- Main Loop ---
do {
    Clear-Host
    Write-Log "=== Winget 패키지 추가 도구 (v5.2 Final) ===" -Color Cyan

    # --- [2] User Input & Duplicate Check ---
    $repoUrl = Read-Host "👉 GitHub Repo URL 입력 (예: https://github.com/owner/repo)"
    if ($repoUrl -match "github\.com/([^/]+)/([^/]+)") {
        $owner = $matches[1]
        # [수정됨] 문자열 에러 핸들링 강화: TrimEnd('/') 추가 후 -replace 사용
        # .git/ 형태로 끝나는 URL이나 .git 확장자 처리를 확실하게 함
        $repoName = $matches[2].TrimEnd('/') -replace "\.git$", ""
        $fullRepo = "$owner/$repoName"
    } else {
        Write-Log "잘못된 URL 형식입니다." -Level ERROR
        continue
    }

    $pkgIdInput = Read-Host "👉 Package ID 입력 (Enter로 기본값 사용: $owner.$repoName)"
    $pkgId = if ([string]::IsNullOrWhiteSpace($pkgIdInput)) { "$owner.$repoName" } else { $pkgIdInput }

    # 중복 ID 체크 로직
    $yamlPath = "packages.yml"
    $skipYamlUpdate = $false
    $enc = New-Object System.Text.UTF8Encoding($false)

    if (Test-Path $yamlPath) {
        $existingContent = [System.IO.File]::ReadAllText($yamlPath, $enc)
        if ($existingContent -match "(?m)^\s*-\s*id:\s*$pkgId\s*$") {
            Write-Log "⚠️ 이미 등록된 Package ID입니다: $pkgId" -Level WARN
            $action = Read-Host "매니페스트(버전)만 업데이트 하시겠습니까? (y=업데이트 진행 / n=취소)"
            
            if ($action -eq 'y' -or $action -eq 'Y') {
                $skipYamlUpdate = $true
                Write-Log "YAML 등록을 건너뛰고 매니페스트 생성 단계로 이동합니다." -Color Green
            } else {
                Write-Log "작업을 취소하고 처음으로 돌아갑니다." -Level WARN
                continue
            }
        }
    }

    # --- [3] GitHub Release Info & Asset Selection (Modified Logic) ---
    Write-Log "🔍 $fullRepo 릴리스 정보 조회 중..." -Color Cyan
    $releaseInfo = $null

    # 3-1. 우선 정식 Latest 시도
    try {
        $releaseInfo = gh api "repos/$fullRepo/releases/latest" 2>$null | ConvertFrom-Json
    } catch {
        $releaseInfo = $null
    }

    # 3-2. 정식 Latest 실패 시, Fallback (Pre-release 포함 최신 검색)
    if (-not $releaseInfo) {
        Write-Log "⚠️ Latest(Stable) release를 찾지 못했습니다." -Level WARN
        Write-Log "   (Pre-release 포함) 가장 최신 버전을 검색합니다..." -Color Gray
        
        $recentList = $null
        try {
            # per_page=1로 가장 최근 것 1개만 가져옴
            $recentList = gh api "repos/$fullRepo/releases?per_page=1" 2>$null | ConvertFrom-Json
        } catch {
            Write-Log "릴리스 정보를 전혀 가져올 수 없습니다. (권한 혹은 존재 여부 확인)" -Level ERROR
            continue
        }

        if ($recentList -and $recentList.Count -gt 0) {
            $candidate = $recentList[0]
            $tagName = $candidate.tag_name
            $isPre = $candidate.prerelease

            Write-Log "🔎 발견된 버전: $tagName (Prerelease: $isPre)" -Color Magenta
            $confirm = Read-Host "👉 이 버전을 사용하시겠습니까? (y/n - Enter=Yes)"
            
            if ([string]::IsNullOrWhiteSpace($confirm) -or $confirm -match '^[yY]') {
                $releaseInfo = $candidate
            } else {
                Write-Log "사용자가 작업을 중단했습니다." -Level WARN
                continue
            }
        } else {
            Write-Log "이 레포지토리에는 릴리스가 하나도 없습니다." -Level ERROR
            continue
        }
    }

    # Assets 확인
    if (-not $releaseInfo.assets) {
        Write-Log "선택된 릴리스($($releaseInfo.tag_name))에 자산(Assets)이 없습니다." -Level ERROR
        continue
    }

    $assets = $releaseInfo.assets | Select-Object Name, @{N='SizeMB';E={[math]::Round($_.size/1MB, 2)}}, browser_download_url
    Write-Log "팝업창에서 자산을 선택하세요..." -Color Yellow
    
    $selectedAsset = $assets | Out-GridView -Title "패키지로 등록할 파일 선택 ($pkgId)" -PassThru

    if (-not $selectedAsset) {
        Write-Log "자산이 선택되지 않았습니다. 취소합니다." -Level WARN
        continue
    }

    # Regex 생성
    $ext = [System.IO.Path]::GetExtension($selectedAsset.Name)
    $generatedRegex = '\' + $ext + '$' 
    
    $regexInput = Read-Host "👉 Asset Regex 확인 (Enter로 기본값 사용: '$generatedRegex')"
    $assetRegex = if ([string]::IsNullOrWhiteSpace($regexInput)) { $generatedRegex } else { $regexInput }

    # --- [4] packages.yml Update (Safely) ---
    if (-not $skipYamlUpdate) {
        if (Test-Path $yamlPath) {
            $currentContent = [System.IO.File]::ReadAllText($yamlPath, $enc)
        } else {
            $currentContent = ""
        }

        if ($currentContent -notmatch '(?m)^\s*packages:\s*$') {
            if ($currentContent.Trim().Length -gt 0) {
                Write-Log "packages 헤더가 누락되어 상단에 추가합니다." -Level WARN
                $currentContent = "packages:`n" + $currentContent
            } else {
                $currentContent = "packages:`n"
                Write-Log "새 packages.yml 파일을 초기화합니다." -Level SUCCESS
            }
        }

        if (-not $currentContent.EndsWith("`n")) {
            $currentContent += "`n"
        }

        $newEntry = "  - id: $pkgId`n    repo: $fullRepo`n    asset_regex: '$assetRegex'`n"
        $finalContent = $currentContent + $newEntry
        
        try {
            Set-Utf8NoBomContent -Path $yamlPath -Content $finalContent
            Write-Log "packages.yml 업데이트 완료" -Level SUCCESS
        } catch {
            Write-Log "packages.yml 쓰기 실패: $_" -Level ERROR
            exit 1
        }
    }

    # --- [5] Manifest Creation (New vs Update) ---
    Write-Log "📦 Manifest 작업 시작 ($pkgId)..." -Color Cyan
    $manifestDir = Join-Path "manifests" $pkgId

    $targetUrl = $null
    foreach ($asset in $releaseInfo.assets) {
        if ($asset.name -match $assetRegex) {
            $targetUrl = $asset.browser_download_url
            break
        }
    }

    if ($targetUrl) {
        # 태그명에서 'v' 접두사 제거
        $version = $releaseInfo.tag_name -replace "^v", ""
        
        Write-Log "Target URL: $targetUrl"
        Write-Log "Target Version: $version"

        if (Test-Path $manifestDir) {
            # [Case A] 기존 패키지 업데이트
            Write-Log "🔄 기존 Manifest 업데이트를 시도합니다 (wingetcreate update)..." -Color Yellow
            try {
                wingetcreate update $pkgId -u $targetUrl -v $version | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "Manifest 업데이트 성공!" -Level SUCCESS
                    $addedPackages += @{Id=$pkgId; Repo=$fullRepo; Tag=$releaseInfo.tag_name; Type="Update"}
                } else {
                    Write-Log "wingetcreate update 실패 (ExitCode: $LASTEXITCODE)" -Level ERROR
                }
            } catch {
                Write-Log "wingetcreate update 실행 중 예외 발생: $_" -Level ERROR
            }
        } else {
            # [Case B] 신규 패키지 생성
            Write-Log "✨ 새 Manifest 생성을 시도합니다 (wingetcreate new)..." -Color Green
            try {
                wingetcreate new $targetUrl -o $manifestDir -f yaml | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "Manifest 생성 성공!" -Level SUCCESS
                    $addedPackages += @{Id=$pkgId; Repo=$fullRepo; Tag=$releaseInfo.tag_name; Type="New"}
                } else {
                    Write-Log "wingetcreate new 실패 (ExitCode: $LASTEXITCODE)" -Level ERROR
                }
            } catch {
                Write-Log "wingetcreate new 실행 중 예외 발생: $_" -Level ERROR
            }
        }
    } else {
        Write-Log "Regex($assetRegex)와 일치하는 자산을 찾을 수 없습니다." -Level ERROR
    }

    # --- [6] Loop Check ---
    $choice = Read-Host "`n🔄 다른 패키지를 추가하시겠습니까? (y/n)"
} while ($choice -eq 'y' -or $choice -eq 'Y')

# --- [7] Git Sync (Pull & Push) ---
Write-Log "☁️ Git 동기화 준비 중..." -Color Cyan
$gitStatus = git status --porcelain

if (-not $gitStatus) {
    Write-Log "변경 사항이 없습니다 (no changes)." -Level WARN
    exit 0
}

if ($addedPackages.Count -gt 0) {
    Write-Log "원격 저장소 변경사항 확인 중 (Pull --rebase)..."
    git pull --rebase --autostash | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Git Pull 실패. 수동으로 충돌을 해결해야 합니다." -Level ERROR
        exit 1
    }

    Write-Log "변경 사항을 스테이징합니다..."
    git add packages.yml manifests/

    # Action별 커밋 메시지 생성
    $commitMsg = ($addedPackages | ForEach-Object { 
        $action = if ($_.Type -eq "Update") { "update" } else { "add" }
        "$action $($_.Id) ($($_.Repo)@$($_.Tag))"
    }) -join ", "
    
    Write-Log "커밋 중: $commitMsg"
    git commit -m $commitMsg

    Write-Log "원격 저장소로 푸시 중..." -Color Yellow
    git push

    if ($LASTEXITCODE -eq 0) {
        Write-Log "모든 작업이 완료되었습니다! (Pushed to remote)" -Level SUCCESS
    } else {
        Write-Log "Git Push 실패" -Level ERROR
        exit 1
    }
} else {
    Write-Log "성공적으로 처리된 패키지가 없어 커밋을 건너뜁니다." -Level WARN
}