<#
.SYNOPSIS
    One-shot bootstrap for ApiForwarder on a fresh Windows Server.
    Installs the .NET 8 Hosting Bundle, enables IIS, creates the site/app pool,
    deploys the app once, and (optionally) installs the GitHub Actions runner so
    every future "git push" auto-deploys.

.DESCRIPTION
    Run in an *elevated* PowerShell prompt on the server:

        irm https://raw.githubusercontent.com/smmrastegar/apiforwarder/claude/http-forwarder-ui-VVsZF/deploy/bootstrap.ps1 | iex

    Or, to also set up auto-deploy in the same run, download then call with a token:

        $b = "https://raw.githubusercontent.com/smmrastegar/apiforwarder/claude/http-forwarder-ui-VVsZF/deploy/bootstrap.ps1"
        irm $b -OutFile $env:TEMP\bootstrap.ps1
        & $env:TEMP\bootstrap.ps1 -RunnerToken "<TOKEN_FROM_GITHUB>"

    Get <TOKEN_FROM_GITHUB> from:
      repo -> Settings -> Actions -> Runners -> New self-hosted runner -> Windows
      (copy the value after `--token` in the ./config.cmd line)
#>
[CmdletBinding()]
param(
    [string]$RepoUrl    = "https://github.com/smmrastegar/apiforwarder.git",
    [string]$RepoHttp   = "https://github.com/smmrastegar/apiforwarder",
    [string]$Branch     = "claude/http-forwarder-ui-VVsZF",
    [string]$SrcDir     = "C:\src\apiforwarder",
    [string]$SiteName   = "apiforwarder",
    [string]$AppPool    = "apiforwarder",
    [string]$SitePath   = "C:\inetpub\apiforwarder",
    [string]$HostName   = "api.lto.bz",
    [int]   $Port       = 80,
    [string]$AdminUser  = "smmr",
    [string]$AdminPassword = "",   # if empty, you'll be prompted (kept out of logs)
    [string]$RunnerToken = "",     # if provided, installs the auto-deploy runner
    [string]$Token = ""            # GitHub PAT (repo:read) for cloning a PRIVATE repo
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# For a private repo, build an authenticated clone URL from the PAT.
$CloneUrl = $RepoUrl
if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $CloneUrl = $RepoUrl -replace '^https://', "https://x-access-token:$Token@"
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Please run this script in an elevated (Administrator) PowerShell prompt."
    }
}

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

function Test-Command($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
}

# ---------------------------------------------------------------------------
Assert-Admin
Write-Host "ApiForwarder bootstrap - automated setup" -ForegroundColor Green
Write-Host "Site: $HostName  |  Path: $SitePath  |  Branch: $Branch"

# 1) ----------------------------------------------------------- Git ---------
Write-Step "Checking Git"
if (-not (Test-Command git)) {
    Write-Host "Git not found; installing via winget..."
    if (Test-Command winget) {
        winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
        Refresh-Path
    } else {
        throw "Git is not installed and winget is unavailable. Install Git manually: https://git-scm.com/download/win"
    }
}
git --version

# 2) ------------------------------------------- .NET 8 Hosting Bundle -------
Write-Step "Checking .NET 8 Hosting Bundle (ASP.NET Core Module for IIS)"
$hasAspNet8 = $false
try {
    if (Test-Command dotnet) {
        $rt = & dotnet --list-runtimes 2>$null
        if ($rt -match "Microsoft\.AspNetCore\.App 8\.") { $hasAspNet8 = $true }
    }
} catch {}

if (-not $hasAspNet8) {
    Write-Host "Downloading and installing .NET 8 Hosting Bundle..."
    # Stable aka.ms link that always points to the latest 8.0 hosting bundle.
    $bundleUrl = "https://aka.ms/dotnet/8.0/dotnet-hosting-win.exe"
    $bundleExe = Join-Path $env:TEMP "dotnet-hosting-8-win.exe"
    Invoke-WebRequest -Uri $bundleUrl -OutFile $bundleExe -UseBasicParsing
    Write-Host "Installing (silent)..."
    $p = Start-Process -FilePath $bundleExe -ArgumentList "/install","/quiet","/norestart" -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        throw "Hosting Bundle install failed with exit code $($p.ExitCode)."
    }
    Write-Host "Hosting Bundle installed. Restarting IIS..."
    Refresh-Path
} else {
    Write-Host "ASP.NET Core 8 runtime already present."
}

# 3) -------------------------------------------------- Enable IIS -----------
Write-Step "Enabling IIS features"
$features = @(
    "IIS-WebServerRole","IIS-WebServer","IIS-CommonHttpFeatures","IIS-StaticContent",
    "IIS-DefaultDocument","IIS-HttpErrors","IIS-RequestFiltering","IIS-HttpLogging",
    "IIS-ApplicationDevelopment","IIS-NetFxExtensibility45","IIS-ISAPIExtensions",
    "IIS-ISAPIFilter","IIS-ManagementConsole","IIS-WebSockets"
)
foreach ($f in $features) {
    try { Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart -ErrorAction Stop | Out-Null }
    catch { Write-Warning "Could not enable $f : $($_.Exception.Message)" }
}

# Restart IIS so the freshly installed ASP.NET Core Module is picked up.
try { & iisreset /restart | Out-Null } catch { try { net stop was /y; net start w3svc } catch {} }

Import-Module WebAdministration -ErrorAction SilentlyContinue

# 4) ----------------------------------------------- Clone / update repo -----
Write-Step "Fetching source from GitHub"
if (Test-Path (Join-Path $SrcDir ".git")) {
    Write-Host "Repo exists; updating..."
    git -C $SrcDir remote set-url origin $CloneUrl
    git -C $SrcDir fetch origin $Branch
    git -C $SrcDir checkout $Branch
    git -C $SrcDir reset --hard "origin/$Branch"
    # Don't leave the token sitting in .git/config.
    git -C $SrcDir remote set-url origin $RepoUrl
} else {
    New-Item -ItemType Directory -Path (Split-Path $SrcDir) -Force | Out-Null
    git clone --branch $Branch $CloneUrl $SrcDir
    if (Test-Path (Join-Path $SrcDir ".git")) {
        git -C $SrcDir remote set-url origin $RepoUrl
    }
}

# 5) ------------------------------------------------- IIS site + pool -------
Write-Step "Creating IIS site and app pool"
& "$SrcDir\deploy\setup-iis.ps1" -SiteName $SiteName -AppPool $AppPool -SitePath $SitePath -HostName $HostName -Port $Port

# 6) ---------------------------------------------- Admin credentials --------
Write-Step "Setting admin panel username/password (stored as Machine env vars)"
if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
    $sec = Read-Host "Enter a password for the admin panel (user: $AdminUser)" -AsSecureString
    $AdminPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
[Environment]::SetEnvironmentVariable("Admin__Username", $AdminUser,     "Machine")
[Environment]::SetEnvironmentVariable("Admin__Password", $AdminPassword, "Machine")
Write-Host "Admin password saved (Machine env var - not in logs or repo)."

# 7) ----------------------------------------------- First deploy ------------
Write-Step "First build and deploy"
# Ensure dotnet is on PATH after the hosting bundle install.
Refresh-Path
if (-not (Test-Command dotnet)) {
    # Hosting bundle ships the runtime but not always the SDK; install SDK if needed for publish.
    Write-Host "dotnet SDK not found; installing .NET 8 SDK..."
    $sdkScript = Join-Path $env:TEMP "dotnet-install.ps1"
    Invoke-WebRequest "https://dot.net/v1/dotnet-install.ps1" -OutFile $sdkScript -UseBasicParsing
    & $sdkScript -Channel 8.0 -InstallDir "C:\Program Files\dotnet"
    Refresh-Path
}

$publishDir = Join-Path $SrcDir "publish"
if (Test-Path $publishDir) { Remove-Item $publishDir -Recurse -Force }
& dotnet publish "$SrcDir\src\ApiForwarder\ApiForwarder.csproj" -c Release -o $publishDir
& "$SrcDir\deploy\deploy.ps1" -PublishDir $publishDir -SitePath $SitePath -AppPool $AppPool

# Recycle the pool so the new Admin__* env vars are read.
try { Restart-WebAppPool -Name $AppPool } catch {}

# 8) -------------------------------------------- Optional: auto-deploy ------
if (-not [string]::IsNullOrWhiteSpace($RunnerToken)) {
    Write-Step "Installing GitHub Actions runner for auto-deploy"
    & "$SrcDir\deploy\install-runner.ps1" -RepoUrl $RepoHttp -Token $RunnerToken
    Write-Host "Runner installed. Every push to '$Branch' will now auto-deploy." -ForegroundColor Green
} else {
    Write-Host "`n(Optional) To auto-deploy on every push, install the runner:" -ForegroundColor Yellow
    Write-Host "  Get a token from repo -> Settings -> Actions -> Runners -> New self-hosted runner -> Windows, then:"
    Write-Host "  & '$SrcDir\deploy\install-runner.ps1' -RepoUrl $RepoHttp -Token <TOKEN>"
}

# 9) ----------------------------------------------- Local smoke test --------
Write-Step "Local health check"
Start-Sleep -Seconds 3
try {
    $h = Invoke-WebRequest "http://localhost:$Port/health" -Headers @{ Host = $HostName } -UseBasicParsing -TimeoutSec 15
    Write-Host "health => HTTP $($h.StatusCode): $($h.Content)" -ForegroundColor Green
} catch {
    Write-Warning "Health check failed (the app may still be warming up): $($_.Exception.Message)"
}

Write-Host "`n==================== DONE ====================" -ForegroundColor Green
Write-Host "Admin panel:  http://$HostName/admin/   (user: $AdminUser)"
Write-Host "On Cloudflare, point $HostName (Proxied) to this server's IP."
Write-Host "For HTTPS: create an Origin Certificate and add a port 443 binding (SSL/TLS = Full strict)."
