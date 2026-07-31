[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$runtimeDirectory = Join-Path $workspaceRoot 'apps\bit_share_flutter\windows\runtime'
$temporaryDirectory = Join-Path $workspaceRoot 'tmp\windows-runtime-download'

New-Item -ItemType Directory -Force -Path $runtimeDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $temporaryDirectory | Out-Null

function Get-VerifiedDownload {
    param(
        [Parameter(Mandatory)]
        [string] $Uri,
        [Parameter(Mandatory)]
        [string] $Destination,
        [Parameter(Mandatory)]
        [string] $ExpectedSha256
    )

    # --silent: curl's progress meter writes to stderr even on success, and
    # PowerShell 5.1 promotes that into a terminating NativeCommandError
    # under $ErrorActionPreference = 'Stop' — this avoids that entirely
    # rather than masking real failures, which --fail still catches.
    & curl.exe `
        --fail `
        --silent `
        --show-error `
        --location `
        --retry 3 `
        --connect-timeout 20 `
        --max-time 120 `
        --output $Destination `
        $Uri
    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo descargar $Uri (curl: $LASTEXITCODE)."
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "Hash SHA-256 incorrecto para $Destination. Esperado: $ExpectedSha256. Actual: $actual."
    }
}

$headers = @{ 'User-Agent' = 'Bit-Share-Windows-Runtime' }

Write-Host 'Consultando la versión estable de yt-dlp...'
$ytDlpRelease = Invoke-RestMethod `
    -Headers $headers `
    -Uri 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest'
$ytDlpAsset = $ytDlpRelease.assets | Where-Object name -eq 'yt-dlp.exe'
if ($null -eq $ytDlpAsset -or -not $ytDlpAsset.digest.StartsWith('sha256:')) {
    throw 'La publicación oficial de yt-dlp no incluye el ejecutable o su hash.'
}
$ytDlpPath = Join-Path $runtimeDirectory 'yt-dlp.exe'
Get-VerifiedDownload `
    -Uri $ytDlpAsset.browser_download_url `
    -Destination $ytDlpPath `
    -ExpectedSha256 $ytDlpAsset.digest.Substring(7)

$ffmpegPath = Join-Path $runtimeDirectory 'ffmpeg.exe'
$ffmpegReady = $false
$ffmpegPackage = '8.1.2-essentials_build'
if (Test-Path -LiteralPath $ffmpegPath) {
    $ffmpegVersion = & $ffmpegPath -version 2>$null | Select-Object -First 1
    $ffmpegReady = $LASTEXITCODE -eq 0 -and $ffmpegVersion -like 'ffmpeg version 8.1.2*'
    if ($ffmpegVersion -like '*full_build*') {
        $ffmpegPackage = '8.1.2-full_build'
    }
}
if (-not $ffmpegReady) {
    Write-Host 'Descargando FFmpeg 8.1.2 essentials...'
    $ffmpegArchive = Join-Path $temporaryDirectory 'ffmpeg-8.1.2-essentials_build.zip'
    Get-VerifiedDownload `
        -Uri 'https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-8.1.2-essentials_build.zip' `
        -Destination $ffmpegArchive `
        -ExpectedSha256 'db580001caa24ac104c8cb856cd113a87b0a443f7bdf47d8c12b1d740584a2ec'
    $ffmpegExpanded = Join-Path $temporaryDirectory 'ffmpeg-expanded'
    if (Test-Path -LiteralPath $ffmpegExpanded) {
        Remove-Item -LiteralPath $ffmpegExpanded -Recurse -Force
    }
    Expand-Archive -LiteralPath $ffmpegArchive -DestinationPath $ffmpegExpanded
    $ffmpegBinary = Get-ChildItem `
        -LiteralPath $ffmpegExpanded `
        -Recurse `
        -File `
        -Filter 'ffmpeg.exe' |
        Select-Object -First 1
    if ($null -eq $ffmpegBinary) {
        throw 'El paquete de FFmpeg no contiene ffmpeg.exe.'
    }
    Copy-Item `
        -LiteralPath $ffmpegBinary.FullName `
        -Destination $ffmpegPath `
        -Force
} else {
    Write-Host 'FFmpeg 8.1.2 ya está preparado.'
}

Write-Host 'Consultando la versión estable de Deno para el soporte de YouTube...'
$denoRelease = Invoke-RestMethod `
    -Headers $headers `
    -Uri 'https://api.github.com/repos/denoland/deno/releases/latest'
$denoAsset = $denoRelease.assets |
    Where-Object name -eq 'deno-x86_64-pc-windows-msvc.zip'
if ($null -eq $denoAsset -or -not $denoAsset.digest.StartsWith('sha256:')) {
    throw 'La publicación oficial de Deno no incluye el paquete Windows o su hash.'
}
$denoArchive = Join-Path $temporaryDirectory 'deno-windows-x64.zip'
Get-VerifiedDownload `
    -Uri $denoAsset.browser_download_url `
    -Destination $denoArchive `
    -ExpectedSha256 $denoAsset.digest.Substring(7)
$denoExpanded = Join-Path $temporaryDirectory 'deno-expanded'
if (Test-Path -LiteralPath $denoExpanded) {
    Remove-Item -LiteralPath $denoExpanded -Recurse -Force
}
Expand-Archive -LiteralPath $denoArchive -DestinationPath $denoExpanded
Copy-Item `
    -LiteralPath (Join-Path $denoExpanded 'deno.exe') `
    -Destination (Join-Path $runtimeDirectory 'deno.exe') `
    -Force

$versions = @(
    "yt-dlp=$($ytDlpRelease.tag_name)"
    "ffmpeg=$ffmpegPackage"
    "deno=$($denoRelease.tag_name)"
)
$versions | Set-Content `
    -LiteralPath (Join-Path $runtimeDirectory 'VERSIONS.txt') `
    -Encoding utf8

Write-Host ''
Write-Host 'Runtime Windows preparado:'
$versions | ForEach-Object { Write-Host "  $_" }
