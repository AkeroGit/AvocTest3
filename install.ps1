#!/usr/bin/env pwsh
#Requires -Version 5.1

param(
    [string]$Prefix = ""
)

# Interactive prompt if no parameter
if ([string]::IsNullOrWhiteSpace($Prefix)) {
    Write-Host "AVoc Installer" -ForegroundColor Cyan
    Write-Host "==============" -ForegroundColor Cyan
    Write-Host ""
    $choice = Read-Host "Use custom path (1) or current directory (0)? [1/0]"

    if ($choice -eq "0") {
        $Prefix = Join-Path (Get-Location) "avoc-install"
        Write-Host "Using current directory: $Prefix"
    } else {
        $custom = Read-Host "Enter installation directory [$env:LOCALAPPDATA\AVoc]"
        if ([string]::IsNullOrWhiteSpace($custom)) {
            $Prefix = "$env:LOCALAPPDATA\AVoc"
        } else {
            $Prefix = $custom
        }
    }
}

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ParentDir = Split-Path -Parent $ScriptDir

Write-Host "Installing AVoc to: $Prefix" -ForegroundColor Green
New-Item -ItemType Directory -Force -Path $Prefix | Out-Null

$env:PATH = "$UvDir;$env:PATH"

# Install Python 3.12.3 specifically
Write-Host "Installing Python 3.12.3..."
& "$UvDir\uv.exe" python install 3.12.3

$VenvDir = "$Prefix\.venv"
& "$UvDir\uv.exe" venv --python 3.12.3 $VenvDir

# Install avoc
Write-Host "Installing AVoc..."
& "$UvDir\uv.exe" pip install --python "$VenvDir\Scripts\python.exe" $ParentDir

# Create launcher
$BinDir = "$Prefix\bin"
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

@'
@echo off
set "AVOC_ROOT=%~dp0.."
"%AVOC_ROOT%\.venv\Scripts\python.exe" -m avoc %*
'@ | Set-Content -Path "$BinDir\avoc.cmd"

Write-Host ""
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host "Python: 3.12.3"
Write-Host "Run: $Prefix\bin\avoc.cmd"
