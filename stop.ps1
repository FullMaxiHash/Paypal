$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
$taskRegistryPath = Join-Path $PSScriptRoot '.tools/processes.local.json'
if (-not (Test-Path -LiteralPath $taskRegistryPath -PathType Leaf)) {
  Write-Host 'No DealSphere launcher processes recorded.'
  exit 0
}
$taskRegistryText = Get-Content -LiteralPath $taskRegistryPath -Raw -Encoding UTF8
$taskRegistry = $taskRegistryText | ConvertFrom-Json
if ($null -eq $taskRegistry -or $taskRegistry -isnot [pscustomobject]) { throw 'Invalid launcher process registry. No processes were stopped.' }

function Get-TaskProcessState {
  param([uint32]$TaskProcessId, [string]$TaskScriptPath, [string]$TaskStartedAt)
  $taskProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $TaskProcessId" -ErrorAction Stop
  if (-not $taskProcess) { return [pscustomobject]@{ State = 'Missing'; Process = $null; StartedAt = $null } }
  $taskActualStart = ([datetime]$taskProcess.CreationDate).ToUniversalTime()
  if ($TaskStartedAt) {
    $taskExpectedStart = [datetimeoffset]::Parse($TaskStartedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None).UtcDateTime
    # CIM timestamps are microsecond-resolution; Get-Process can retain finer ticks.
    if ([math]::Abs(($taskActualStart - $taskExpectedStart).TotalMilliseconds) -gt 1) {
      return [pscustomobject]@{ State = 'Reused'; Process = $taskProcess; StartedAt = $taskActualStart.ToString('o') }
    }
  }
  if ($taskProcess.Name -ine 'node.exe' -or -not $taskProcess.CommandLine) {
    return [pscustomobject]@{ State = 'Unowned'; Process = $taskProcess; StartedAt = $taskActualStart.ToString('o') }
  }
  # The launcher invokes node.exe followed immediately by an absolute script path.
  # Match that argument, never a later string merely mentioning this workspace.
  $taskCommand = [regex]::Match($taskProcess.CommandLine, '^\s*(?:"[^"]+"|[^\s"]+)\s+(?:"(?<script>[^"]+)"|(?<script>[^\s"]+))(?=\s|$)')
  if (-not $taskCommand.Success) {
    return [pscustomobject]@{ State = 'Unowned'; Process = $taskProcess; StartedAt = $taskActualStart.ToString('o') }
  }
  $taskScriptArgument = $taskCommand.Groups['script'].Value.Replace('/', '\')
  if (-not [IO.Path]::IsPathRooted($taskScriptArgument)) {
    return [pscustomobject]@{ State = 'Unowned'; Process = $taskProcess; StartedAt = $taskActualStart.ToString('o') }
  }
  $taskActualScript = [IO.Path]::GetFullPath($taskScriptArgument)
  $taskExpectedScript = [IO.Path]::GetFullPath($TaskScriptPath)
  if (-not [string]::Equals($taskActualScript, $taskExpectedScript, [StringComparison]::OrdinalIgnoreCase)) {
    return [pscustomobject]@{ State = 'Unowned'; Process = $taskProcess; StartedAt = $taskActualStart.ToString('o') }
  }
  return [pscustomobject]@{ State = 'Owned'; Process = $taskProcess; StartedAt = $taskActualStart.ToString('o') }
}

function Wait-TaskProcessExit {
  param([uint32]$TaskProcessId, [string]$TaskScriptPath, [string]$TaskStartedAt)
  $taskDeadline = [datetime]::UtcNow.AddSeconds(5)
  do {
    $taskState = Get-TaskProcessState $TaskProcessId $TaskScriptPath $TaskStartedAt
    if ($taskState.State -in @('Missing', 'Reused')) { return $true }
    if ($taskState.State -ne 'Owned') { throw 'A recorded process could no longer be verified. Its registry was retained.' }
    Start-Sleep -Milliseconds 100
  } while ([datetime]::UtcNow -lt $taskDeadline)
  return $false
}

function Stop-TaskHelperTree {
  param([uint32]$TaskProcessId, [string]$TaskScriptPath, [string]$TaskStartedAt)
  $taskState = Get-TaskProcessState $TaskProcessId $TaskScriptPath $TaskStartedAt
  if ($taskState.State -in @('Missing', 'Reused')) { return }
  if ($taskState.State -ne 'Owned') { throw 'Refusing to stop a process whose launcher ownership cannot be verified.' }
  $taskKill = Join-Path ([Environment]::GetFolderPath('System')) 'taskkill.exe'
  $taskKillOutput = & $taskKill /PID ([string]$TaskProcessId) /T /F 2>&1
  $taskKillCode = $LASTEXITCODE
  # A process may exit between inspection and taskkill. Its absence is authoritative.
  if (-not (Wait-TaskProcessExit $TaskProcessId $TaskScriptPath $TaskStartedAt)) {
    if ($taskKillCode -ne 0) { Write-Warning 'Windows did not confirm termination of an owned helper.' }
    throw 'A launcher helper is still running. The process registry was retained.'
  }
  $null = $taskKillOutput
}

$taskRecords = @()
foreach ($taskKind in @('web', 'postgres')) {
  $taskRawId = $taskRegistry.$taskKind
  if ($null -eq $taskRawId) { continue }
  [uint32]$taskProcessId = 0
  if (-not [uint32]::TryParse([string]$taskRawId, [ref]$taskProcessId) -or $taskProcessId -eq 0) {
    throw 'The launcher process registry contains an invalid process ID. No processes were stopped.'
  }
  $taskRelativeScript = if ($taskKind -eq 'web') { 'scripts/run-next.mjs' } else { 'scripts/local-postgres.mjs' }
  $taskScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $taskRelativeScript))
  $taskMetadataName = $taskKind + 'StartedAt'
  $taskStartedAt = [string]$taskRegistry.$taskMetadataName
  $taskState = Get-TaskProcessState $taskProcessId $taskScript $taskStartedAt
  if ($taskState.State -notin @('Missing', 'Owned')) {
    throw 'A recorded PID belongs to another or unverifiable process. No processes were stopped; the registry was retained.'
  }
  $taskRecords += [pscustomobject]@{ Kind = $taskKind; ProcessId = $taskProcessId; Script = $taskScript; StartedAt = $taskState.StartedAt; InitialState = $taskState.State }
}

# Stop the application before shutting down its database. No port-based kill is used.
foreach ($taskRecord in @($taskRecords | Where-Object { $_.Kind -eq 'web' -and $_.InitialState -eq 'Owned' })) {
  Stop-TaskHelperTree $taskRecord.ProcessId $taskRecord.Script $taskRecord.StartedAt
}

foreach ($taskRecord in @($taskRecords | Where-Object { $_.Kind -eq 'postgres' -and $_.InitialState -eq 'Owned' })) {
  $taskState = Get-TaskProcessState $taskRecord.ProcessId $taskRecord.Script $taskRecord.StartedAt
  if ($taskState.State -in @('Missing', 'Reused')) { continue }
  if ($taskState.State -ne 'Owned') { throw 'The local database helper ownership changed. The process registry was retained.' }
  $taskPostmasters = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($taskRecord.ProcessId)" -ErrorAction Stop | Where-Object { $_.Name -ieq 'postgres.exe' })
  if ($taskPostmasters.Count -gt 1) { throw 'The local database helper has an unexpected process tree. No database process was stopped.' }
  if ($taskPostmasters.Count -eq 1) {
    # Recheck the helper immediately before asking pg_ctl to stop its own child.
    $taskState = Get-TaskProcessState $taskRecord.ProcessId $taskRecord.Script $taskRecord.StartedAt
    if ($taskState.State -ne 'Owned') { throw 'The local database helper ended or changed before shutdown. No database shutdown was requested.' }
    $taskNode = $null
    $taskRuntimeFile = Join-Path $PSScriptRoot '.tools/runtime.local.json'
    if (Test-Path -LiteralPath $taskRuntimeFile -PathType Leaf) {
      $taskRuntime = Get-Content -LiteralPath $taskRuntimeFile -Raw -Encoding UTF8 | ConvertFrom-Json
      $taskNode = [string]$taskRuntime.node
    }
    if (-not $taskNode) {
      $taskNodeCommand = Get-Command node -CommandType Application -ErrorAction SilentlyContinue
      if ($taskNodeCommand) { $taskNode = $taskNodeCommand.Source }
    }
    if (-not $taskNode -or -not [IO.Path]::IsPathRooted($taskNode) -or -not (Test-Path -LiteralPath $taskNode -PathType Leaf)) { throw 'A local Node runtime is required for graceful database shutdown. The process registry was retained.' }
    $taskPostmaster = $taskPostmasters[0]
    & $taskNode (Join-Path $PSScriptRoot 'scripts/stop-postgres.mjs') --expected-pid ([string]$taskPostmaster.ProcessId)
    if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL did not confirm graceful shutdown. The database helper and process registry were retained.' }
    $taskStillRunning = Get-CimInstance Win32_Process -Filter "ProcessId = $($taskPostmaster.ProcessId)" -ErrorAction Stop
    if ($taskStillRunning -and ([datetime]$taskStillRunning.CreationDate).ToUniversalTime() -eq ([datetime]$taskPostmaster.CreationDate).ToUniversalTime()) {
      throw 'The database server is still running. Its helper and registry were retained.'
    }
  } else {
    $taskInitializers = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($taskRecord.ProcessId)" -ErrorAction Stop | Where-Object { $_.Name -ieq 'initdb.exe' })
    if ($taskInitializers.Count -gt 0) { throw 'The local database is still initializing. Retry shutdown after initialization finishes.' }
    # No owned postmaster exists. Never target a listener or another database here.
  }
  Stop-TaskHelperTree $taskRecord.ProcessId $taskRecord.Script $taskRecord.StartedAt
}

foreach ($taskRecord in $taskRecords) {
  $taskState = Get-TaskProcessState $taskRecord.ProcessId $taskRecord.Script $taskRecord.StartedAt
  if ($taskState.State -notin @('Missing', 'Reused')) { throw 'A recorded process has not ended. The process registry was retained.' }
}
if ((Get-Content -LiteralPath $taskRegistryPath -Raw -Encoding UTF8) -cne $taskRegistryText) {
  Write-Host 'The original launcher processes stopped. A changed process registry was preserved.'
  exit 0
}
Remove-Item -LiteralPath $taskRegistryPath
Write-Host 'DealSphere launcher processes stopped. PostgreSQL data is preserved.'
