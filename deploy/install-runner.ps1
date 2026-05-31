<#
.SYNOPSIS
    Installs a GitHub Actions self-hosted runner on the Windows server and
    registers it as a Windows service so deploys happen automatically on push.

.DESCRIPTION
    Run once in an *elevated* PowerShell prompt.

    Get a registration token first:
      GitHub repo -> Settings -> Actions -> Runners -> "New self-hosted runner"
      -> choose Windows. Copy the token shown in the `./config.cmd ... --token` line.

    The runner must have the 'windows' label (this script adds it) so the
    workflow's `runs-on: [self-hosted, windows]` matches.

.EXAMPLE
    .\deploy\install-runner.ps1 -RepoUrl https://github.com/smmrastegar/apiforwarder -Token AAA...
#>
param(
    [Parameter(Mandatory = $true)] [string]$RepoUrl,
    [Parameter(Mandatory = $true)] [string]$Token,
    [string]$RunnerDir = "C:\actions-runner",
    [string]$RunnerName = "$env:COMPUTERNAME-iis",
    [string]$Labels = "self-hosted,windows,iis"
)

$ErrorActionPreference = "Stop"

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) { throw "Please run this script as Administrator." }

New-Item -ItemType Directory -Path $RunnerDir -Force | Out-Null
Set-Location $RunnerDir

# Resolve the latest runner release version from GitHub.
Write-Host "==> Finding latest runner version..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/actions/runner/releases/latest" `
    -Headers @{ "User-Agent" = "apiforwarder-setup" }
$version = $release.tag_name.TrimStart("v")
$zip = "actions-runner-win-x64-$version.zip"
$url = "https://github.com/actions/runner/releases/download/v$version/$zip"

if (-not (Test-Path (Join-Path $RunnerDir "config.cmd"))) {
    Write-Host "==> Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile (Join-Path $RunnerDir $zip)
    Write-Host "==> Extracting..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $RunnerDir $zip), $RunnerDir)
    Remove-Item (Join-Path $RunnerDir $zip) -Force
}

Write-Host "==> Configuring runner..."
& "$RunnerDir\config.cmd" --unattended --url $RepoUrl --token $Token `
    --name $RunnerName --labels $Labels --runasservice --replace

Write-Host ""
Write-Host "==> Runner installed and running as a service." -ForegroundColor Green
Write-Host "    NOTE: the runner service account needs permission to manage IIS"
Write-Host "    and write to the site folder. The simplest reliable option is to"
Write-Host "    run the service as an admin account:"
Write-Host "      services.msc -> 'GitHub Actions Runner (...)' -> Log On -> This account"
Write-Host "    (use the Windows admin user/password you already have)."
