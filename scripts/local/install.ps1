[CmdletBinding()]
param(
    [switch]$PrepareOnly,
    [string]$InstallPrefix = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$taskRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$taskUtf8 = New-Object System.Text.UTF8Encoding($false)
$taskRun = $null
$taskLogStarted = $false
$taskLock = $null

function Invoke-TaskCommand {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed (exit $LASTEXITCODE): $Executable $($Arguments -join ' ')"
    }
}

function Get-TaskOutput {
    param([string]$Executable, [string[]]$Arguments)
    $taskLines = & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed: $Executable $($Arguments -join ' ')" }
    return (($taskLines | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Find-TaskZig {
    param([string]$Architecture)
    $taskZigVersion = '0.16.0'
    $taskExisting = Get-Command zig.exe -ErrorAction SilentlyContinue
    if ($taskExisting) {
        if ((Get-TaskOutput $taskExisting.Source @('version')) -eq $taskZigVersion) {
            return $taskExisting.Source
        }
        Write-Host 'PATH Zig version differs from 0.16.0; using the project-local toolchain.'
    }
    $taskPlatform = if ($Architecture -eq 'x64') { 'x86_64-windows' } else { 'aarch64-windows' }
    $taskDigest = if ($Architecture -eq 'x64') {
        '68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e'
    } else {
        'aee38316ee4111717900f45dd3130145c39289e105541d737eb8c5ed653c78ef'
    }
    $taskTools = Join-Path $taskRepo '.local-tools'
    $taskName = "zig-$taskPlatform-$taskZigVersion"
    $taskCompiler = Join-Path $taskTools "$taskName\zig.exe"
    if (-not (Test-Path -LiteralPath $taskCompiler)) {
        New-Item -ItemType Directory -Path $taskTools -Force | Out-Null
        $taskArchive = Join-Path $taskTools "$taskName.zip"
        if ((Test-Path -LiteralPath $taskArchive) -and
            ((Get-FileHash -LiteralPath $taskArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskDigest)) {
            throw "Cached Zig archive checksum mismatch. Remove this specific file and retry: $taskArchive"
        }
        if (-not (Test-Path -LiteralPath $taskArchive)) {
            $taskPartial = Join-Path $taskTools ("download-" + [guid]::NewGuid().ToString('N') + '.zip')
            $taskCurl = (Get-Command curl.exe -ErrorAction Stop).Source
            Write-Host 'Downloading official Zig 0.16.0 (first run only)...'
            Invoke-TaskCommand $taskCurl @(
                '--fail', '--location', '--show-error', '--retry', '2',
                '--connect-timeout', '20', '--max-time', '300',
                '--output', $taskPartial,
                "https://ziglang.org/download/$taskZigVersion/$taskName.zip"
            )
            if ((Get-FileHash -LiteralPath $taskPartial -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskDigest) {
                throw "Downloaded Zig checksum mismatch. The previous codex-auth installation was not changed."
            }
            Move-Item -LiteralPath $taskPartial -Destination $taskArchive
        }
        Write-Host 'Extracting the verified compiler...'
        $taskTar = Get-Command tar.exe -ErrorAction SilentlyContinue
        if ($taskTar) {
            Invoke-TaskCommand $taskTar.Source @('-xf', $taskArchive, '-C', $taskTools)
        } else {
            Expand-Archive -LiteralPath $taskArchive -DestinationPath $taskTools -Force
        }
    }
    if ((Get-TaskOutput $taskCompiler @('version')) -ne $taskZigVersion) {
        throw 'The cached compiler is not Zig 0.16.0.'
    }
    return $taskCompiler
}

function New-TaskTarball {
    param([string]$Binary)
    $taskStage = Join-Path $taskRun 'package'
    Invoke-TaskCommand $taskNode @(
        (Join-Path $PSScriptRoot 'stage-package.mjs'), $taskRepo, $Binary,
        $taskStage, $taskArchitecture
    )
    $taskPackJson = Get-TaskOutput $taskNpm @(
        'pack', $taskStage, '--offline', '--ignore-scripts', '--json', '--pack-destination', $taskRun
    )
    $taskPacked = @($taskPackJson | ConvertFrom-Json)
    if ($taskPacked.Count -ne 1) { throw 'npm pack did not return exactly one package.' }
    $taskTarball = Join-Path $taskRun ([IO.Path]::GetFileName([string]$taskPacked[0].filename))
    if (-not (Test-Path -LiteralPath $taskTarball)) { throw 'npm pack did not create the tarball.' }
    return $taskTarball
}

function Assert-TaskInstalled {
    param([string]$Root, [string]$ExpectedHash)
    $taskPackage = Join-Path $Root '@loongphy\codex-auth'
    $taskInstalledBinary = Join-Path $taskPackage 'bin\native\codex-auth.exe'
    if (-not (Test-Path -LiteralPath $taskInstalledBinary)) { throw 'Installed local binary was not found.' }
    if ((Get-FileHash -LiteralPath $taskInstalledBinary -Algorithm SHA256).Hash -ne $ExpectedHash) {
        throw 'Installed executable does not match the compiled local binary.'
    }
    Invoke-TaskCommand $taskNode @((Join-Path $taskPackage 'bin\codex-auth.cjs'), '--version')
}

try {
    if ($env:OS -ne 'Windows_NT') { throw 'This installer requires Windows.' }
    Set-Location -LiteralPath $taskRepo
    $taskNode = (Get-Command node.exe -ErrorAction Stop).Source
    $taskNpm = (Get-Command npm.cmd -ErrorAction Stop).Source
    $taskArchitecture = Get-TaskOutput $taskNode @('-p', 'process.arch')
    if ($taskArchitecture -notin @('x64', 'arm64')) { throw 'Only Windows x64 and ARM64 are supported.' }
    $taskDist = Join-Path $taskRepo 'dist\local'
    New-Item -ItemType Directory -Path $taskDist -Force | Out-Null
    try {
        $taskLock = [IO.File]::Open((Join-Path $taskDist 'installer.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    } catch { throw 'Another local installer is already running. Wait for it to finish.' }
    $taskRun = Join-Path $taskDist ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $taskRun | Out-Null
    Start-Transcript -Path (Join-Path $taskRun 'install.log') | Out-Null
    $taskLogStarted = $true
    Write-Host "Repository: $taskRepo"
    Write-Host "Build output and log: $taskRun"
    Invoke-TaskCommand $taskNode @('scripts/npm/check-versions.mjs')
    Invoke-TaskCommand $taskNode @('scripts/npm/check-release-metadata.mjs')
    $taskZig = Find-TaskZig $taskArchitecture
    $taskTarget = if ($taskArchitecture -eq 'x64') { 'x86_64-windows-gnu' } else { 'aarch64-windows-gnu' }
    Write-Host 'Building the current local source (ReleaseSafe)...'
    Invoke-TaskCommand $taskZig @('build', "-Dtarget=$taskTarget", '-Doptimize=ReleaseSafe', '--prefix', (Join-Path $taskRun 'zig'))
    $taskBinary = Join-Path $taskRun 'zig\bin\codex-auth.exe'
    Invoke-TaskCommand $taskBinary @('--version')
    $taskBinaryHash = (Get-FileHash -LiteralPath $taskBinary -Algorithm SHA256).Hash
    $taskNew = New-TaskTarball $taskBinary
    Write-Host 'Checking the tarball in an isolated npm installation...'
    $taskSmoke = Join-Path $taskRun 'smoke'
    Invoke-TaskCommand $taskNpm @(
        'install', '--prefix', $taskSmoke, '--offline', '--ignore-scripts',
        '--no-audit', '--no-fund', '--package-lock=false', $taskNew
    )
    Assert-TaskInstalled (Join-Path $taskSmoke 'node_modules') $taskBinaryHash
    Invoke-TaskCommand $taskNode @(
        (Join-Path $PSScriptRoot 'smoke.mjs'),
        (Join-Path $taskSmoke 'node_modules\@loongphy\codex-auth\bin\codex-auth.cjs'),
        (Join-Path $taskRun 'smoke-codex-home')
    )
    [IO.File]::WriteAllText((Join-Path $taskDist 'latest-package.txt'), $taskNew, $taskUtf8)
    if ($PrepareOnly) {
        Write-Host "PREPARE ONLY: package verified; the global installation was not changed."
        Write-Host "Package: $taskNew"
    } else {
        $taskPrefixArgs = @()
        if ($InstallPrefix) {
            $taskPrefixArgs = @('--prefix', [IO.Path]::GetFullPath($InstallPrefix))
        }
        $taskGlobalRoot = Get-TaskOutput $taskNpm (@('root', '--global') + $taskPrefixArgs)
        Write-Host 'Uninstalling the current npm codex-auth package...'
        Invoke-TaskCommand $taskNpm (@('uninstall', '--global', '--ignore-scripts', '@loongphy/codex-auth') + $taskPrefixArgs)
        Write-Host 'Installing the verified local tarball...'
        Invoke-TaskCommand $taskNpm (@(
            'install', '--global', '--offline', '--ignore-scripts', '--no-audit', '--no-fund', $taskNew
        ) + $taskPrefixArgs)
        Assert-TaskInstalled $taskGlobalRoot $taskBinaryHash
        $taskPrefix = Get-TaskOutput $taskNpm (@('prefix', '--global') + $taskPrefixArgs)
        Invoke-TaskCommand (Join-Path $taskPrefix 'codex-auth.cmd') @('--version')
        Write-Host 'SUCCESS: the local fork is installed. Account files were not deleted or copied.'
        Write-Host "Installed command: $(Join-Path $taskPrefix 'codex-auth.cmd')"
        Write-Host 'If another codex-auth appears earlier on PATH, remove that duplicate or use the full path above.'
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($taskRun) { Write-Host "Details and build artifacts: $taskRun" }
    exit 1
} finally {
    if ($taskLogStarted) { Stop-Transcript | Out-Null }
    if ($taskLock) { $taskLock.Dispose() }
}
