#Requires -Version 7
[CmdletBinding()]
param(
    [string]$OutputDir = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$OutputDir = [IO.Path]::GetFullPath($OutputDir, (Get-Location).Path)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$PrivatePath = Join-Path $OutputDir "LauncherSigning.private.xml"
$PublicPath = Join-Path $OutputDir "LauncherSigning.public.xml"
if ((Test-Path -LiteralPath $PrivatePath) -or (Test-Path -LiteralPath $PublicPath)) {
    throw "Signing key already exists in $OutputDir"
}

$Rsa = [Security.Cryptography.RSACryptoServiceProvider]::new(3072)
try {
    [IO.File]::WriteAllText($PrivatePath, $Rsa.ToXmlString($true), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($PublicPath, $Rsa.ToXmlString($false), [Text.UTF8Encoding]::new($false))
} finally {
    $Rsa.PersistKeyInCsp = $false
    $Rsa.Dispose()
}

Write-Host "Private key (keep secret): $PrivatePath"
Write-Host "Public key:              $PublicPath"
