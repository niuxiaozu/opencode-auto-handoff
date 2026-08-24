# ctx.ps1 - one-shot context occupancy reporter for the session-handoff skill.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\ctx.ps1" [SessionId]
# Prints: session id/title/model, latest-turn token breakdown, occupancy vs model window.
param([string]$SessionId = "")
$ErrorActionPreference = 'SilentlyContinue'

# ---- 1. discover opencode server port ----
$port = $null
$regDir = Join-Path $env:USERPROFILE '.config\openchamber\managed-opencode'
# (a) exact registry entry for the current opencode pid
$pidEnv = $env:OPENCODE_PID
if ($pidEnv -and (Test-Path $regDir)) {
  $exact = Join-Path $regDir "$pidEnv.json"
  if (Test-Path $exact) {
    try { $port = (Get-Content $exact -Raw | ConvertFrom-Json).port } catch { }
  }
}
# (b) newest registry entry
if (-not $port -and (Test-Path $regDir)) {
  $latest = Get-ChildItem $regDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($latest) { try { $port = (Get-Content $latest.FullName -Raw | ConvertFrom-Json).port } catch { } }
}
# (c) netstat scan for the pid
if (-not $port -and $pidEnv) {
  $listeners = netstat -ano | Select-String "LISTENING"
  foreach ($l in $listeners) {
    $cols = ($l.ToString() -split '\s+' | Where-Object { $_ -ne '' })
    if ($cols.Count -ge 5 -and $cols[4] -eq $pidEnv -and $cols[1] -match '^127\.0\.0\.1:(\d+)$') { $port = $Matches[1]; break }
  }
}
if (-not $port) { Write-Output 'ERR: cannot locate opencode server port'; exit 1 }

$user = $env:OPENCODE_SERVER_USERNAME
$pass = $env:OPENCODE_SERVER_PASSWORD
if (-not $user -or -not $pass) { Write-Output 'ERR: OPENCODE_SERVER_USERNAME/PASSWORD missing'; exit 1 }
$b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${user}:${pass}"))
$headers = @{ Authorization = "Basic $b64" }
$base = "http://127.0.0.1:$port"

# ---- 2. pick session: explicit arg, else most recently updated parentless session ----
$dir = (Get-Location).Path
try {
  $sessions = Invoke-RestMethod -Uri "$base/session?directory=$([uri]::EscapeDataString($dir))" -Headers $headers -TimeoutSec 15
} catch { Write-Output "ERR: session list failed: $($_.Exception.Message)"; exit 1 }
if (-not $sessions) { Write-Output 'ERR: no sessions returned'; exit 1 }
$s = $null
if ($SessionId) { $s = $sessions | Where-Object { $_.id -eq $SessionId } | Select-Object -First 1 }
if (-not $s) {
  $sorted = $sessions | Sort-Object { $_.time.updated } -Descending
  $s = $sorted | Where-Object { -not $_.parentID } | Select-Object -First 1
  if (-not $s) { $s = $sorted | Select-Object -First 1 }
}

# ---- 3. latest-turn token snapshot (input + cache.read = current prompt size) ----
$input = 0; $cacheRead = 0; $output = 0; $reasoning = 0; $snapshotMsg = 'n/a'
try {
  $msgs = Invoke-RestMethod -Uri "$base/session/$([uri]::EscapeDataString($s.id))/message?limit=10" -Headers $headers -TimeoutSec 15
  $last = $null
  for ($i = $msgs.Count - 1; $i -ge 0; $i--) {
    $t = $msgs[$i].info.tokens
    if ($t -and ($t.input -gt 0 -or $t.output -gt 0 -or $t.cache.read -gt 0)) { $last = $msgs[$i]; break }
  }
  if ($last) {
    $t = $last.info.tokens
    $input = [double]$t.input; $output = [double]$t.output; $reasoning = [double]$t.reasoning
    if ($t.cache) { $cacheRead = [double]$t.cache.read }
    $snapshotMsg = $last.id
  }
} catch { Write-Output "ERR: message fetch failed: $($_.Exception.Message)"; exit 1 }

# ---- 4. model context window from local models.json ----
$limit = $null
$modelsPath = Join-Path $env:USERPROFILE '.cache\opencode\models.json'
$providerID = $s.model.providerID; $modelID = $s.model.id
if (Test-Path $modelsPath) {
  $raw = [System.IO.File]::ReadAllText($modelsPath)
  $pidx = $raw.IndexOf('"' + $providerID + '"')
  if ($pidx -ge 0) {
    $midx = $raw.IndexOf('"' + $modelID + '"', $pidx)
    if ($midx -ge 0) {
      $m = [regex]::Match($raw.Substring($midx), '"limit"\s*:\s*\{\s*"context"\s*:\s*(\d+)')
      if ($m.Success) { $limit = [double]$m.Groups[1].Value }
    }
  }
}
if (-not $limit) { $limit = 262144 }

$occupied = $input + $cacheRead + $output + $reasoning
$pct = [math]::Round(100.0 * $occupied / $limit, 1)

function Fmt([double]$n) {
  if ($n -ge 1e9) { return ("{0:N1}G" -f ($n / 1e9)) }
  if ($n -ge 1e6) { return ("{0:N1}M" -f ($n / 1e6)) }
  if ($n -ge 1e3) { return ("{0:N0}K" -f ($n / 1e3)) }
  return [string]$n
}

Write-Output ("session: {0} | {1} | {2}/{3}" -f $s.id, $s.title, $providerID, $modelID)
Write-Output ("tokens(latest turn): input={0} cache_read={1} output={2} reasoning={3}  (msg {4})" -f (Fmt $input), (Fmt $cacheRead), (Fmt $output), (Fmt $reasoning), $snapshotMsg)
Write-Output ("occupancy: {0} / {1} = {2}%" -f (Fmt $occupied), (Fmt $limit), $pct)
Write-Output "NOTE: this is the latest-turn snapshot; right after a context compaction it may under-report."
