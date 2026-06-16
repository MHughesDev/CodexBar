#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Target,

    [string]$Thumbprint,

    [string]$TimestampUrl = 'http://timestamp.digicert.com',

    [switch]$UseAzureTrustedSigning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-SignTool {
    $kitsBase = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    if (-not (Test-Path $kitsBase)) {
        throw "Windows 10 SDK not found at '$kitsBase'. Install it from https://developer.microsoft.com/windows/downloads/windows-sdk/"
    }

    $candidate = Get-ChildItem -Path $kitsBase -Filter 'signtool.exe' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -match '\\x64$' } |
        Sort-Object -Property FullName -Descending |
        Select-Object -First 1

    if (-not $candidate) {
        throw "signtool.exe not found under '$kitsBase'. Install the Windows 10 SDK signing tools."
    }

    return $candidate.FullName
}

if (-not (Test-Path $Target)) {
    throw "Target '$Target' does not exist."
}

$signtool = Find-SignTool
Write-Host "signtool: $signtool"
Write-Host "Target:   $Target"

$baseArgs = @(
    'sign',
    '/fd', 'SHA256',
    '/td', 'SHA256',
    '/tr', $TimestampUrl
)

if ($UseAzureTrustedSigning) {
    # Azure Trusted Signing requires the Microsoft.Trusted.Signing.Client NuGet package
    # and AZURE_TENANT_ID / AZURE_CLIENT_ID / AZURE_CLIENT_SECRET (or managed identity) in the environment.
    # The dlib path is typically resolved by the CI pipeline after restoring the package.
    $dlibPath = $env:ATS_DLIB_PATH
    if (-not $dlibPath) {
        $dlibPath = Join-Path $PSScriptRoot '..\packages\Microsoft.Trusted.Signing.Client\*\bin\x64\Azure.CodeSigning.Dlib.dll'
        $dlibPath = (Resolve-Path $dlibPath -ErrorAction SilentlyContinue | Select-Object -Last 1)?.Path
    }
    if (-not $dlibPath -or -not (Test-Path $dlibPath)) {
        throw "Azure Trusted Signing dlib not found. Set ATS_DLIB_PATH or restore the Microsoft.Trusted.Signing.Client NuGet package."
    }
    $metadataPath = Join-Path $PSScriptRoot 'ats-metadata.json'
    if (-not (Test-Path $metadataPath)) {
        throw "Azure Trusted Signing metadata file not found at '$metadataPath'. Create it per https://learn.microsoft.com/azure/trusted-signing/how-to-signing-integrations"
    }
    $signArgs = $baseArgs + @('/dlib', $dlibPath, '/dmdf', $metadataPath, $Target)
} elseif ($Thumbprint) {
    $signArgs = $baseArgs + @('/sha1', $Thumbprint, $Target)
} else {
    throw "Provide -Thumbprint <cert-thumbprint> or -UseAzureTrustedSigning."
}

Write-Host "Running: $signtool $($signArgs -join ' ')"
& $signtool @signArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "signtool exited with code $LASTEXITCODE. Signing FAILED."
    exit $LASTEXITCODE
}

Write-Host "Signed successfully: $Target"
