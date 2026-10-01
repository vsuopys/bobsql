#requires -Version 7.0
<#
    Ward General Hospital — Hyperscale developer demo
    build.ps1 : build the .NET application in this kit.

    Usage:
      ./build.ps1                          # dotnet build (Debug)
      ./build.ps1 -Configuration Release   # release build
      ./build.ps1 -Publish                 # dotnet publish to ./app/publish
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',

    [switch]$Publish
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$solution = Join-Path $root 'WardGeneral.slnx'
$webProj = Join-Path $root 'src' 'WardGeneral.Web' 'WardGeneral.Web.csproj'

if (-not (Test-Path $webProj)) {
    throw "Web project not found: $webProj"
}

Write-Host "Building the solution ($Configuration)..." -ForegroundColor Cyan
dotnet build $solution -c $Configuration --nologo
if ($LASTEXITCODE -ne 0) { throw "dotnet build failed (exit $LASTEXITCODE)." }

if ($Publish) {
    $out = Join-Path $root 'src' 'WardGeneral.Web' 'publish'
    Write-Host "Publishing the web app to $out..." -ForegroundColor Cyan
    dotnet publish $webProj -c $Configuration -o $out --nologo
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed (exit $LASTEXITCODE)." }
}

# Ensure the DAB CLI — a runtime dependency of the chat/agent (SQL MCP at :5000).
if (Get-Command dab -ErrorAction SilentlyContinue) {
    Write-Host "DAB CLI present." -ForegroundColor DarkGray
}
else {
    Write-Host "Installing DAB CLI (Microsoft.DataApiBuilder)..." -ForegroundColor Yellow
    dotnet tool install --global Microsoft.DataApiBuilder
    # The DAB tool package has no win-arm64 RID; on Windows on ARM install it with the
    # x64 .NET host (runs under emulation) if it's present.
    $x64Dotnet = Join-Path $env:ProgramFiles 'dotnet\x64\dotnet.exe'
    if ($LASTEXITCODE -ne 0 -and [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64' -and (Test-Path $x64Dotnet)) {
        Write-Host "  win-arm64: retrying with the x64 .NET host ($x64Dotnet)..." -ForegroundColor Yellow
        & $x64Dotnet tool install --global Microsoft.DataApiBuilder
    }
    if ($LASTEXITCODE -ne 0) { throw "DAB CLI install failed (needed for the chat/agent)." }
}

Write-Host "Build succeeded." -ForegroundColor Green
