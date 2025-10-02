[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string]$Config = ".\config.json",

  [Parameter(Mandatory=$false)]
  [string]$OutFile = ".\data.json",

  [int]$WatchSeconds = 0
)

# -------- Helpers --------
function Resolve-RelPath([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $p }
  if ([System.IO.Path]::IsPathRooted($p)) { return [IO.Path]::GetFullPath($p) }
  $base = $PSScriptRoot
  if ([string]::IsNullOrWhiteSpace($base)) { $base = (Get-Location).Path }
  return [IO.Path]::GetFullPath((Join-Path $base $p))
}

$Config  = Resolve-RelPath $Config
$OutFile = Resolve-RelPath $OutFile

function Set-Tls {
  param([bool]$IgnoreCert = $false)
  try {
    [Net.ServicePointManager]::SecurityProtocol =
      [Net.SecurityProtocolType]::Tls12 -bor
      [Net.SecurityProtocolType]::Tls11 -bor
      [Net.SecurityProtocolType]::Tls
  } catch {}

  if ($IgnoreCert) {
    # typed scriptblock -> RemoteCertificateValidationCallback
    $cb = {
      param($sender, $cert, $chain, $errors)
      return $true
    }
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $cb
  }
}

function Get-Json([string]$path) {
  if (-not (Test-Path $path)) { throw "Config not found: $path" }
  Get-Content $path -Raw | ConvertFrom-Json
}

function Invoke-VoneLogin($cfg) {
  $tokenUrl = ($cfg.baseUrl.TrimEnd('/')) + "/api/token"

  $body = @{
    username      = $cfg.username
    password      = $cfg.password
    grant_type    = 'password'
    refresh_token = ''
  }

  $headers = @{ Accept = 'application/json' }

  $resp = Invoke-RestMethod -Method POST -Uri $tokenUrl `
            -Headers $headers `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body $body

  if (-not $resp.access_token) { throw "Login failed: no access_token" }
  return $resp
}

function Get-VoneTriggeredAlarms($cfg, $accessToken) {
  $ver   = if ($cfg.apiVersion) { $cfg.apiVersion } else { 'v2.3' }
  $limit = if ($cfg.limit)      { [int]$cfg.limit } else { 100 }
  $url = "{0}/api/{1}/alarms/triggeredAlarms?Offset=0&Limit={2}" -f ($cfg.baseUrl.TrimEnd('/')), $ver, $limit

  $headers = @{
    Accept        = 'application/json'
    Authorization = "Bearer $accessToken"
  }

  Invoke-RestMethod -Method GET -Uri $url -Headers $headers
}

function Write-DataJson($path, $payload, $cfg) {
  $dir = Split-Path -Parent $path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  if (Test-Path $path) { Remove-Item -Force $path }

  $obj = [ordered]@{
    generatedAt   = (Get-Date).ToUniversalTime().ToString("o")
    sourceBaseUrl = $cfg.baseUrl
    totalCount    = $payload.totalCount
    items         = $payload.items
  }
  $json = ($obj | ConvertTo-Json -Depth 6)
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($path), $json, [Text.UTF8Encoding]::new($false))
}

# -------- Main loop --------
$cfg = Get-Json $Config
Set-Tls -IgnoreCert:([bool]$cfg.ignoreSslErrors)

do {
  try {
    Write-Host ("[{0}] Logging in..." -f (Get-Date))
    $tok = Invoke-VoneLogin $cfg

    Write-Host ("[{0}] Token OK (expires_in={1}s). Fetching alarms..." -f (Get-Date), $tok.expires_in)
    $data = Get-VoneTriggeredAlarms $cfg $tok.access_token

    $count   = if ($data.items) { $data.items.Count } else { 0 }
    $outFull = [IO.Path]::GetFullPath($OutFile)
    Write-Host ("[{0}] Received {1} items (totalCount={2}). Writing {3}..." -f (Get-Date), $count, $data.totalCount, $outFull)

    Write-DataJson -path $OutFile -payload $data -cfg $cfg
    Write-Host ("[{0}] Done." -f (Get-Date)) -ForegroundColor Green
  }
  catch {
    Write-Warning ("[{0}] ERROR: {1}" -f (Get-Date), $_.Exception.Message)
  }

  if ($WatchSeconds -gt 0) { Start-Sleep -Seconds $WatchSeconds }
} while ($WatchSeconds -gt 0)
