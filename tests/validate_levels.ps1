# Runs the level validator (tests/validate_levels.gd) and prints its report.
#
#   .\tests\validate_levels.ps1                 every level
#   .\tests\validate_levels.ps1 -Level apr_01   one level
#   .\tests\validate_levels.ps1 -Strict         warnings count as failures
#
# Works from any directory. Godot is looked up on PATH first, then in the
# Steam install; set $env:GODOT to point somewhere else.
param(
    [string]$Level = "",
    [switch]$Strict
)

$project = Split-Path -Parent $PSScriptRoot

$godot = $env:GODOT
if (-not $godot) {
    $onPath = Get-Command godot -ErrorAction SilentlyContinue
    if ($onPath) { $godot = $onPath.Source }
}
if (-not $godot) {
    $godot = "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
}
if (-not (Test-Path $godot)) {
    Write-Host "Godot not found. Set `$env:GODOT to the path of the Godot executable." -ForegroundColor Red
    exit 2
}

$godotArgs = @("--headless", "--path", "`"$project`"", "res://tests/ValidateLevels.tscn")
$userArgs = @()
if ($Level -ne "") { $userArgs += "--level=$Level" }
if ($Strict) { $userArgs += "--strict" }
if ($userArgs.Count -gt 0) { $godotArgs += "--"; $godotArgs += $userArgs }

# Godot is a windowed program, so its output is captured to a file and the
# script waits for it; run directly, PowerShell would return at once and show
# nothing.
$out = [System.IO.Path]::GetTempFileName()
$err = [System.IO.Path]::GetTempFileName()
Start-Process -FilePath $godot -ArgumentList $godotArgs -Wait -NoNewWindow `
    -RedirectStandardOutput $out -RedirectStandardError $err | Out-Null

# Keep the report; drop the engine's own start-up and shutdown chatter.
$report = Get-Content $out | Where-Object {
    $_ -and ($_ -notmatch '^Godot Engine') -and ($_ -notmatch 'Unreferenced static string') -and
    ($_ -notmatch '^\s+at: ') -and ($_ -notmatch 'leaked at exit') -and ($_ -notmatch 'PagedAllocator') -and
    ($_ -notmatch 'still in use at exit')
}
foreach ($line in $report) {
    if ($line -match 'ERROR') { Write-Host $line -ForegroundColor Red }
    elseif ($line -match 'warn ') { Write-Host $line -ForegroundColor Yellow }
    elseif ($line -match '^RESULT: OK') { Write-Host $line -ForegroundColor Green }
    elseif ($line -match '^RESULT: FAIL') { Write-Host $line -ForegroundColor Red }
    else { Write-Host $line }
}
$failed = -not ($report -match '^RESULT: OK')
Remove-Item $out, $err -ErrorAction SilentlyContinue
if ($failed) { exit 1 } else { exit 0 }
