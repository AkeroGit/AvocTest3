#!/usr/bin/env pwsh
#Requires -Version 5.1

param(
    [string]$Prefix = "",
    [switch]$NoShortcuts,
    [switch]$SkipConnectivityCheck
)

if ([string]::IsNullOrWhiteSpace($Prefix)) {
    Write-Host "AVoc Installer" -ForegroundColor Cyan
    Write-Host "=============="
    $choice = Read-Host "Use custom path (1) or current directory (0)? [1/0]"
    
    if ($choice -eq "0") {
        $Prefix = Join-Path (Get-Location) "avoc-install"
    } else {
        $custom = Read-Host "Enter installation directory [$env:LOCALAPPDATA\AVoc]"
        $Prefix = if ([string]::IsNullOrWhiteSpace($custom)) { "$env:LOCALAPPDATA\AVoc" } else { $custom }
    }
}

$ErrorActionPreference = "Stop"

# Create directories
New-Item -ItemType Directory -Force -Path $Prefix | Out-Null
$Prefix = (Resolve-Path $Prefix).Path
$UvDir = Join-Path $Prefix ".uv"
$UvExe = Join-Path $UvDir "uv.exe"

Write-Host "Installing AVoc to: $Prefix" -ForegroundColor Green

# Download uv if not present
if (-not (Test-Path $UvExe)) {
    Write-Host "Downloading uv..."
    New-Item -ItemType Directory -Force -Path $UvDir | Out-Null
    $UvInstaller = Join-Path $env:TEMP "uv-install.ps1"
    Invoke-WebRequest -Uri "https://astral.sh/uv/install.ps1" -OutFile $UvInstaller
    [Environment]::SetEnvironmentVariable("UV_UNMANAGED_INSTALL", $UvDir, "Process")
    & $UvInstaller
}

# Install Python 3.12.3
Write-Host "Installing Python 3.12.3..."
$env:UV_PYTHON_INSTALL_DIR = Join-Path $Prefix "python"
& $UvExe python install 3.12.3

# Create venv
$VenvDir = Join-Path $Prefix ".venv"
& $UvExe venv --python 3.12.3 $VenvDir

# Install avoc
Write-Host "Installing AVoc..."
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& $UvExe pip install --python (Join-Path $VenvDir "Scripts\python.exe") $ScriptDir

# Create launcher with portable env vars
$BinDir = Join-Path $Prefix "bin"
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

$LauncherCmd = @"
@echo off
set "AVOC_HOME=$Prefix"
set "AVOC_DATA_DIR=$Prefix\data"
"%AVOC_HOME%\.venv\Scripts\avoc.exe" %*
"@

$LauncherCmd | Set-Content -Path (Join-Path $BinDir "avoc.cmd")

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host "Installation Complete!"
Write-Host "Location: $Prefix"
Write-Host "Run: $Prefix\bin\avoc.cmd"
Write-Host "==============================================" -ForegroundColor Green
