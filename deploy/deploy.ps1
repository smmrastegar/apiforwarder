<#
.SYNOPSIS
    Deploys a published ApiForwarder build into the live IIS site with zero-ish
    downtime, preserving the runtime route store (App_Data\routes.json).

.NOTES
    Run by the GitHub Actions self-hosted runner, but also usable by hand:
        .\deploy\deploy.ps1 -PublishDir .\publish -SitePath C:\inetpub\apiforwarder -AppPool apiforwarder
#>
param(
    [Parameter(Mandatory = $true)] [string]$PublishDir,
    [Parameter(Mandatory = $true)] [string]$SitePath,
    [Parameter(Mandatory = $true)] [string]$AppPool
)

$ErrorActionPreference = "Stop"
Import-Module WebAdministration -ErrorAction SilentlyContinue

Write-Host "==> Deploying from '$PublishDir' to '$SitePath' (app pool: $AppPool)"

if (-not (Test-Path $PublishDir)) { throw "Publish directory not found: $PublishDir" }
if (-not (Test-Path $SitePath))   { New-Item -ItemType Directory -Path $SitePath -Force | Out-Null }

# 1) Tell ASP.NET Core Module to gracefully take the app offline.
$offline = Join-Path $SitePath "app_offline.htm"
Set-Content -Path $offline -Value "<h1>در حال بروزرسانی… Updating…</h1>" -Encoding UTF8

# 2) Stop the app pool so files are unlocked.
if (Get-Item "IIS:\AppPools\$AppPool" -ErrorAction SilentlyContinue) {
    if ((Get-WebAppPoolState -Name $AppPool).Value -ne "Stopped") {
        Stop-WebAppPool -Name $AppPool
    }
    # Wait for the pool to actually stop.
    for ($i = 0; $i -lt 30 -and (Get-WebAppPoolState -Name $AppPool).Value -ne "Stopped"; $i++) {
        Start-Sleep -Milliseconds 500
    }
}

# 3) Mirror the new build over the site, but keep runtime data and logs.
#    /XD excludes directories so the live routes.json and logs survive deploys.
$robolog = robocopy $PublishDir $SitePath /MIR /NFL /NDL /NJH /NJS /NP `
    /XD (Join-Path $SitePath "App_Data") (Join-Path $SitePath "logs") `
    /XF "app_offline.htm"
# robocopy exit codes 0-7 are success; >=8 is a real failure.
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
$global:LASTEXITCODE = 0

# Ensure App_Data exists for the route store.
$dataDir = Join-Path $SitePath "App_Data"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }

# 4) Start the app pool back up.
if (Get-Item "IIS:\AppPools\$AppPool" -ErrorAction SilentlyContinue) {
    Start-WebAppPool -Name $AppPool
}

# 5) Bring the app back online.
Remove-Item $offline -Force -ErrorAction SilentlyContinue

Write-Host "==> Deploy complete."
