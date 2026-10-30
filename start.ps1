param([switch]$Production, [switch]$Development, [switch]$OpenBrowser)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
if ($Production -and $Development) { throw 'Choose Production or Development, not both.' }
$taskRuntime = if (Test-Path -LiteralPath '.tools/runtime.local.json') { Get-Content -LiteralPath '.tools/runtime.local.json' -Raw | ConvertFrom-Json } else { $null }
$taskNode = if ($taskRuntime -and (Test-Path -LiteralPath $taskRuntime.node)) { $taskRuntime.node } else { (Get-Command node -ErrorAction SilentlyContinue).Source }
if (-not $taskNode -or -not (Test-Path -LiteralPath $taskNode)) { throw 'Node.js 22.16+ is required. The local runtime is missing.' }
$env:PATH = (Split-Path -Parent $taskNode) + ';' + $env:PATH
$env:NEXT_TELEMETRY_DISABLED = '1'
New-Item -ItemType Directory -Path '.tools' -Force | Out-Null
$taskMutex = [Threading.Mutex]::new($false, 'Local\DealSphere-3000')
$taskLocked = $false

function Get-DealSphereHealth([string]$Url) {
  try {
    $taskResponse = Invoke-WebRequest -Uri "$Url/api/health" -UseBasicParsing -TimeoutSec 3
    $taskHealth = $taskResponse.Content | ConvertFrom-Json
    return $taskResponse.StatusCode -eq 200 -and $taskHealth.service -eq 'DealSphere' -and $taskHealth.status -eq 'ready'
  } catch { return $false }
}
function Test-LocalListener([int]$Port) {
  $taskSocket = [Net.Sockets.TcpClient]::new()
  try { return $taskSocket.ConnectAsync('127.0.0.1', $Port).Wait(800) -and $taskSocket.Connected } catch { return $false } finally { $taskSocket.Dispose() }
}
function Save-LaunchProcesses($WebProcess, $PgProcess) {
  $taskState = @{}
  foreach ($taskEntry in @(@{ key='web'; process=$WebProcess }, @{ key='postgres'; process=$PgProcess })) {
    if (-not $taskEntry.process) { continue }
    $taskOwned = Get-CimInstance Win32_Process -Filter "ProcessId = $($taskEntry.process.Id)" -ErrorAction SilentlyContinue
    if ($taskOwned -and $taskOwned.Name -eq 'node.exe' -and $taskOwned.CommandLine.Contains($PSScriptRoot)) {
      $taskState[$taskEntry.key] = $taskOwned.ProcessId
      $taskState[$taskEntry.key + 'StartedAt'] = $taskOwned.CreationDate.ToUniversalTime().ToString('o')
    }
  }
  $taskState | ConvertTo-Json | Set-Content -LiteralPath '.tools/processes.local.json' -Encoding UTF8
}
try {
  try { $taskLocked = $taskMutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $taskLocked = $true }
  if (-not $taskLocked) { throw 'Another DealSphere launch is still running. Wait for its window to finish.' }
  & $taskNode scripts/setup-env.mjs
  if ($LASTEXITCODE -ne 0) { throw 'Environment setup failed.' }
  if (-not (Test-Path -LiteralPath 'node_modules/next/package.json')) { throw 'Dependencies are missing. See docs/LOCAL_SETUP.md before installing on this workstation.' }
  $taskConfigText = & $taskNode scripts/launch-check.mjs config
  if ($LASTEXITCODE -ne 0) { throw 'Local environment configuration is invalid.' }
  $taskConfig = $taskConfigText | ConvertFrom-Json
  & $taskNode scripts/run-next.mjs is-built
  $taskBuildReady = $LASTEXITCODE -eq 0
  if ($taskBuildReady -and (Get-DealSphereHealth $taskConfig.url)) {
    Write-Host "DealSphere is already running: $($taskConfig.url)"
    if ($OpenBrowser) { Start-Process -FilePath $taskConfig.url }
    exit 0
  }
  if (Test-LocalListener $taskConfig.port) {
    if (Test-Path -LiteralPath '.tools/processes.local.json') {
      & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'stop.ps1')
      if ($LASTEXITCODE -ne 0) { throw 'The previous owned processes could not be stopped safely.' }
    }
    if (Test-LocalListener $taskConfig.port) { throw 'Port 3000 is occupied by a process this launcher does not own. No unrelated process was stopped.' }
  }
  $taskPg = $null
  if (-not (Test-LocalListener $taskConfig.databasePort)) {
    $taskPgArgs = '"' + (Join-Path $PSScriptRoot 'scripts/local-postgres.mjs') + '"'
    $taskPg = Start-Process -FilePath $taskNode -ArgumentList $taskPgArgs -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -RedirectStandardOutput '.tools/postgres.log' -RedirectStandardError '.tools/postgres-error.log' -PassThru
    Save-LaunchProcesses $null $taskPg
  } elseif (Test-Path -LiteralPath '.tools/processes.local.json') {
    $taskPrevious = Get-Content -LiteralPath '.tools/processes.local.json' -Raw | ConvertFrom-Json
    if ($taskPrevious.postgres) { $taskPg = Get-Process -Id $taskPrevious.postgres -ErrorAction SilentlyContinue }
  }
  $taskDatabaseReady = $false
  for ($taskAttempt = 0; $taskAttempt -lt 20; $taskAttempt++) {
    & $taskNode scripts/launch-check.mjs database
    if ($LASTEXITCODE -eq 0) { $taskDatabaseReady = $true; break }
    Start-Sleep -Milliseconds 700
  }
  if (-not $taskDatabaseReady) { throw 'PostgreSQL did not become ready. See .tools/postgres-error.log.' }
  & $taskNode node_modules/prisma/build/index.js generate
  if ($LASTEXITCODE -ne 0) { throw 'Prisma Client generation failed.' }
  & $taskNode node_modules/prisma/build/index.js migrate deploy
  if ($LASTEXITCODE -ne 0) { throw 'Database migration failed.' }
  & $taskNode node_modules/tsx/dist/cli.mjs prisma/seed.ts
  if ($LASTEXITCODE -ne 0) { throw 'Demo account initialization failed.' }
  if (-not $Development -and -not $taskBuildReady) {
    Write-Host 'Preparing the current production build. This can take about a minute...'
    & $taskNode scripts/run-next.mjs build
    if ($LASTEXITCODE -ne 0) { throw 'Production build failed.' }
  }
  $taskNextScript = '"' + (Join-Path $PSScriptRoot 'scripts/run-next.mjs') + '"'
  $taskWebArgs = if ($Development) { "$taskNextScript dev" } else { "$taskNextScript start" }
  $taskWeb = Start-Process -FilePath $taskNode -ArgumentList $taskWebArgs -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -RedirectStandardOutput '.tools/web.log' -RedirectStandardError '.tools/web-error.log' -PassThru
  Save-LaunchProcesses $taskWeb $taskPg
  $taskReady = $false
  for ($taskAttempt = 0; $taskAttempt -lt 45; $taskAttempt++) {
    if (Get-DealSphereHealth $taskConfig.url) { $taskReady = $true; break }
    if ($taskWeb.HasExited) { break }
    Start-Sleep -Milliseconds 800
  }
  if (-not $taskReady) { throw 'The app did not become ready. See .tools/web.log and .tools/web-error.log.' }
  Write-Host "DealSphere is running and the database is connected: $($taskConfig.url)"
  Write-Host 'Click Buyer or Seller on the sign-in screen; no password entry is required for the demo buttons.'
  if ($OpenBrowser) { Start-Process -FilePath $taskConfig.url }
} finally {
  if ($taskLocked) { $taskMutex.ReleaseMutex() }
  $taskMutex.Dispose()
}
