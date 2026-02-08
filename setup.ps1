<# :
@echo off
chcp 65001 > nul
title Winget Manifest Setup Tool
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([System.IO.File]::ReadAllText('%~f0'))"
pause
goto :eof
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "=== Winget Manifest Setup ===" -ForegroundColor Green
Write-Host ""

if (-not (Test-Path "packages.yml")) {
    Write-Host "❌ packages.yml not found!" -ForegroundColor Red
    Write-Host "   Run add-package.ps1 first." -ForegroundColor Yellow
    exit 1
}

$yamlLines = Get-Content "packages.yml"
$packages = @()
$current = @{}

foreach ($line in $yamlLines) {
    if ($line -match '^\s+- id:\s*(.+)') {
        if ($current.Count -gt 0) { $packages += [PSCustomObject]$current }
        $current = @{ id = $matches[1].Trim() }
    } elseif ($line -match '^\s+repo:\s*(.+)') {
        $current.repo = $matches[1].Trim()
    } elseif ($line -match '^\s+asset_regex:\s*[''"](.+)[''"]') {
        $current.asset_regex = $matches[1].Trim()
    }
}
if ($current.Count -gt 0) { $packages += [PSCustomObject]$current }

Write-Host "📦 Found $($packages.Count) package(s)" -ForegroundColor Cyan
Write-Host ""

foreach ($pkg in $packages) {
    $id = $pkg.id
    $repo = $pkg.repo
    $regex = $pkg.asset_regex
    
    Write-Host "----------------------------------------" -ForegroundColor Gray
    Write-Host "📌 Package: $id" -ForegroundColor Yellow
    Write-Host "   Repo: $repo" -ForegroundColor Gray
    
    $manifestPath = "manifests\$id"
    if (Test-Path $manifestPath) {
        Write-Host "   ✅ Manifest already exists (skip)" -ForegroundColor Green
        continue
    }
    
    Write-Host "   🔍 Fetching latest release..." -ForegroundColor Gray
    try {
        $latest = gh api "repos/$repo/releases/latest" 2>$null | ConvertFrom-Json
        $tag = $latest.tag_name
        
        $asset = $latest.assets | Where-Object { $_.name -match $regex } | Select-Object -First 1
        
        if (-not $asset) {
            Write-Host "   ❌ No matching asset for regex: $regex" -ForegroundColor Red
            continue
        }
        
        $url = $asset.browser_download_url
        Write-Host "   📥 Asset: $($asset.name)" -ForegroundColor Cyan
        
        Write-Host "   🛠️  Creating manifest with wingetcreate..." -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $manifestPath -Force | Out-Null
        
        & wingetcreate new $url -o $manifestPath -f yaml
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   ✅ Manifest created!" -ForegroundColor Green
        } else {
            Write-Host "   ❌ Failed" -ForegroundColor Red
        }
        
    } catch {
        Write-Host "   ❌ Error: $_" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "✅ Setup complete!" -ForegroundColor Green
Write-Host "Next: Commit & push to GitHub" -ForegroundColor Yellow
