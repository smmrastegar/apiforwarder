<#
.SYNOPSIS
    One-time server setup: installs the IIS features, creates the app pool and
    website for ApiForwarder, and sets folder permissions.

.DESCRIPTION
    Run this once on the Windows server in an *elevated* PowerShell prompt.
    IMPORTANT: you must also install the ".NET 8 Hosting Bundle" separately
    (it provides the AspNetCoreModuleV2 used by web.config). Download:
        https://dotnet.microsoft.com/download/dotnet/8.0
        -> "Hosting Bundle" under "ASP.NET Core Runtime"
    Then run: net stop was /y ; net start w3svc   (or just reboot)

.EXAMPLE
    .\deploy\setup-iis.ps1 -SiteName apiforwarder -SitePath C:\inetpub\apiforwarder -HostName api.lto.bz
#>
param(
    [string]$SiteName = "apiforwarder",
    [string]$AppPool  = "apiforwarder",
    [string]$SitePath = "C:\inetpub\apiforwarder",
    [string]$HostName = "api.lto.bz",
    [int]$Port = 80
)

$ErrorActionPreference = "Stop"

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) { throw "Please run this script as Administrator." }

Write-Host "==> Enabling IIS features..."
$features = @(
    "IIS-WebServerRole","IIS-WebServer","IIS-CommonHttpFeatures","IIS-StaticContent",
    "IIS-DefaultDocument","IIS-HttpErrors","IIS-RequestFiltering","IIS-HttpLogging",
    "IIS-ApplicationDevelopment","IIS-NetFxExtensibility45","IIS-ISAPIExtensions",
    "IIS-ISAPIFilter","IIS-ManagementConsole","IIS-WebSockets"
)
foreach ($f in $features) {
    try { Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart -ErrorAction Stop | Out-Null }
    catch { Write-Warning "Could not enable $f ($($_.Exception.Message))" }
}

Import-Module WebAdministration

Write-Host "==> Creating site folder: $SitePath"
New-Item -ItemType Directory -Path $SitePath -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $SitePath "App_Data") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $SitePath "logs") -Force | Out-Null

Write-Host "==> Creating app pool: $AppPool (No Managed Code)"
if (-not (Test-Path "IIS:\AppPools\$AppPool")) {
    New-WebAppPool -Name $AppPool | Out-Null
}
# ASP.NET Core uses the native module, so the pool runs with No Managed Code.
Set-ItemProperty "IIS:\AppPools\$AppPool" -Name managedRuntimeVersion -Value ""
Set-ItemProperty "IIS:\AppPools\$AppPool" -Name startMode -Value "AlwaysRunning"
Set-ItemProperty "IIS:\AppPools\$AppPool" -Name processModel.idleTimeout -Value "00:00:00"

Write-Host "==> Creating website: $SiteName (${HostName}:$Port)"
if (Test-Path "IIS:\Sites\$SiteName") {
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath -Value $SitePath
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name applicationPool -Value $AppPool
} else {
    New-Website -Name $SiteName -PhysicalPath $SitePath -ApplicationPool $AppPool `
        -HostHeader $HostName -Port $Port | Out-Null
}

# Also answer requests without a Host header (handy for health checks).
try {
    New-WebBinding -Name $SiteName -Protocol http -Port $Port -IPAddress "*" -HostHeader "" -ErrorAction SilentlyContinue
} catch {}

Write-Host "==> Granting permissions to the app pool identity..."
$identity = "IIS AppPool\$AppPool"
$acl = Get-Acl $SitePath
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $identity, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.SetAccessRule($rule)
Set-Acl -Path $SitePath -AclObject $acl

Write-Host ""
Write-Host "==> IIS setup complete." -ForegroundColor Green
Write-Host "    Next steps:"
Write-Host "      1) Install the .NET 8 Hosting Bundle if you haven't:"
Write-Host "         https://dotnet.microsoft.com/download/dotnet/8.0 (Hosting Bundle)"
Write-Host "      2) Install the GitHub Actions runner: .\deploy\install-runner.ps1"
Write-Host "      3) Push to the repo - the app will build and deploy automatically."
Write-Host ""
Write-Host "    Cloudflare: point api.lto.bz (proxied) to this server's public IP."
Write-Host "    For TLS, use a Cloudflare Origin Certificate + an https binding on 443,"
Write-Host "    and set SSL/TLS mode to 'Full (strict)'."
