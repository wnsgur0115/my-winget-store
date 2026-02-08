<# :
@echo off
chcp 65001 > nul
title Add Package to packages.yml
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([System.IO.File]::ReadAllText('%~f0'))"
pause
goto :eof
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "=== Winget Package Adder ===" -ForegroundColor Green
Write-Host ""

if (-not (Test-Path "packages.yml")) {
    @"
packages: []
"@ | Set-Content "packages.yml" -Encoding UTF8
    Write-Host "✅ Created packages.yml" -ForegroundColor Yellow
}

Write-Host "📌 Enter GitHub repo URL:" -ForegroundColor Cyan
Write-Host "   Example: https://github.com/Orbmu2k/nvidiaProfileInspector" -ForegroundColor Gray
$repoUrl = Read-Host "URL"

if ([string]::IsNullOrWhiteSpace($repoUrl)) {
    Write-Host "❌ Empty input. Exit." -ForegroundColor Red
    exit 1
}

if ($repoUrl -notmatch "github\.com/([^/]+)/([^/]+)") {
    Write-Host "❌ Invalid GitHub URL format!" -ForegroundColor Red
    exit 1
}

$owner = $matches[1]
$repoName = $matches[2].TrimEnd('.git')
$fullRepo = "$owner/$repoName"

Write-Host ""
Write-Host "🔍 Repository: $fullRepo" -ForegroundColor Yellow

$suggestedId = "$owner.$repoName"
Write-Host ""
Write-Host "📦 Enter Package ID (press Enter to use: $suggestedId)" -ForegroundColor Cyan
$pkgId = Read-Host "ID"
if ([string]::IsNullOrWhiteSpace($pkgId)) {
    $pkgId = $suggestedId
}

Write-Host "   ✅ Package ID: $pkgId" -ForegroundColor Green

Write-Host ""
Write-Host "🌐 Fetching latest release from GitHub..." -ForegroundColor Gray

try {
    $latest = gh api "repos/$fullRepo/releases/latest" 2>$null | ConvertFrom-Json
    
    if (-not $latest) {
        throw "No releases found"
    }
    
    $tag = $latest.tag_name
    Write-Host "   📌 Latest release: $tag" -ForegroundColor Cyan
    
    $assets = $latest.assets
    
    if ($assets.Count -eq 0) {
        Write-Host ""
        Write-Host "❌ No assets found in this release!" -ForegroundColor Red
        Write-Host "   Release URL: $($latest.html_url)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "Opening release page in browser..." -ForegroundColor Yellow
        Start-Process $latest.html_url
        exit 1
    }
    
    Write-Host ""
    Write-Host "📦 Found $($assets.Count) asset(s) in release:" -ForegroundColor Yellow
    Write-Host ""
    
    $useGridView = $true
    if ($env:OS -notmatch "Windows" -or -not (Get-Command Out-GridView -ErrorAction SilentlyContinue)) {
        $useGridView = $false
    }
    
    if ($useGridView) {
        $selected = $assets | Select-Object @{N='Name';E={$_.name}}, @{N='Size (MB)';E={[math]::Round($_.size/1MB, 2)}}, @{N='URL';E={$_.browser_download_url}} | 
            Out-GridView -Title "Select an installer asset" -OutputMode Single
        
        if (-not $selected) {
            Write-Host "❌ No selection. Exit." -ForegroundColor Red
            exit 1
        }
        
        $selectedAsset = $assets | Where-Object { $_.name -eq $selected.Name }
        
    } else {
        for ($i = 0; $i -lt $assets.Count; $i++) {
            Write-Host "  [$($i+1)] $($assets[$i].name) ($([math]::Round($assets[$i].size/1MB, 2)) MB)" -ForegroundColor Gray
        }
        Write-Host ""
        $choice = Read-Host "Select asset number (1-$($assets.Count))"
        
        if (-not ($choice -match '^\d+$') -or [int]$choice -lt 1 -or [int]$choice -gt $assets.Count) {
            Write-Host "❌ Invalid selection!" -ForegroundColor Red
            exit 1
        }
        
        $selectedAsset = $assets[[int]$choice - 1]
    }
    
    $fileName = $selectedAsset.name
    Write-Host ""
    Write-Host "   ✅ Selected: $fileName" -ForegroundColor Green
    
    $ext = [System.IO.Path]::GetExtension($fileName)
    
    if ($ext -eq '.exe') {
        $assetRegex = '\.exe$'
    } elseif ($ext -eq '.msi') {
        $assetRegex = '\.msi$'
    } elseif ($ext -eq '.zip') {
        $assetRegex = '\.zip$'
    } elseif ($ext -eq '.msix') {
        $assetRegex = '\.msix$'
    } else {
        $assetRegex = [regex]::Escape($fileName) + '$'
    }
    
    Write-Host "   🎯 Auto-generated regex: $assetRegex" -ForegroundColor Gray
    Write-Host ""
    Write-Host "If you want a custom regex, edit it now (or press Enter to use above):" -ForegroundColor Yellow
    $customRegex = Read-Host "Custom regex"
    
    if (-not [string]::IsNullOrWhiteSpace($customRegex)) {
        $assetRegex = $customRegex
    }
    
} catch {
    Write-Host ""
    Write-Host "❌ Failed to fetch release info!" -ForegroundColor Red
    Write-Host "   Error: $_" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Opening repo releases page in browser..." -ForegroundColor Yellow
    Start-Process "https://github.com/$fullRepo/releases"
    exit 1
}

Write-Host ""
Write-Host "💾 Adding to packages.yml..." -ForegroundColor Cyan

$yamlContent = Get-Content "packages.yml" -Raw

$newEntry = @"

  - id: $pkgId
    repo: $fullRepo
    asset_regex: '$assetRegex'
"@

if ($yamlContent -match 'packages:\s*\[\s*\]') {
    $yamlContent = $yamlContent -replace 'packages:\s*\[\s*\]', "packages:$newEntry"
} else {
    $yamlContent += $newEntry
}

$yamlContent | Set-Content "packages.yml" -Encoding UTF8

Write-Host "✅ Added successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "📋 Current packages.yml:" -ForegroundColor Yellow
Write-Host ""
Get-Content "packages.yml"
Write-Host ""
Write-Host "Next: Run setup.ps1 to generate manifests" -ForegroundColor Cyan
