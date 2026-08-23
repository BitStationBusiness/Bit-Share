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
    #
    # -C -: resumes from whatever --output already has on disk. Without it,
    # a slow link that never finishes inside --max-time restarts from zero
    # on every retry and can never accumulate enough of a large file (seen
    # in practice: ffmpeg's ~105 MiB archive at ~95 KiB/s over a ~120s cap).
    # The hash check must live *inside* this loop: a stale complete file
    # left over from a previous run (e.g. yesterday's Deno build, before
    # upstream cut a new release) resumes as "already complete" and passes
    # curl fine, but is the wrong bytes — only re-verifying can catch that,
    # and only deleting it lets the next attempt fetch the real thing.
    for ($attempt = 1; $attempt -le 15; $attempt++) {
        & curl.exe `
            --fail `
            --silent `
            --show-error `
            --location `
            --connect-timeout 20 `
            --max-time 120 `
            --continue-at - `
            --output $Destination `
            $Uri
        if ($LASTEXITCODE -eq 0) {
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash.ToLowerInvariant()
            if ($actual -eq $ExpectedSha256.ToLowerInvariant()) { return }
            Remove-Item -LiteralPath $Destination -Force
            if ($attempt -eq 15) {
                throw "Hash SHA-256 incorrecto para $Destination tras $attempt intentos."
            }
            continue
        }
        # Exit 33 is curl refusing to resume a server response it can't
        # verify as a continuation (e.g. a redirect target); a fresh
        # download is the only way forward from there.
        if ($LASTEXITCODE -eq 33 -and (Test-Path -LiteralPath $Destination)) {
            Remove-Item -LiteralPath $Destination -Force
        }
        if ($attempt -eq 15) {
            throw "No se pudo descargar $Uri (curl: $LASTEXITCODE)."
        }
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
$ffprobePath = Join-Path $runtimeDirectory 'ffprobe.exe'
$ffmpegReady = $false
$ffmpegPackage = '8.1.2-essentials_build'
# ffmpeg encodes the edits and ffprobe reads the duration and frame size the
# gallery and the editor need. They are installed and checked as one unit so a
# runtime can never end up with mismatched versions of the two.
if ((Test-Path -LiteralPath $ffmpegPath) -and (Test-Path -LiteralPath $ffprobePath)) {
    # The whole output is collected before the first line is picked out.
    # Piping straight into `Select-Object -First 1` ends the pipeline as soon
    # as it has its line, which kills the still-writing native process and
    # leaves $LASTEXITCODE at 255. That is a race: ffmpeg usually finished in
    # time, ffprobe usually did not, so this check reported "not ready" for a
    # runtime that was perfectly fine and re-downloaded ~100 MB every build —
    # and turned an upstream outage into a failed release.
    $ffmpegOutput = & $ffmpegPath -version 2>$null
    $ffmpegExit = $LASTEXITCODE
    $ffmpegVersion = $ffmpegOutput | Select-Object -First 1
    $ffmpegOk = $ffmpegExit -eq 0 -and $ffmpegVersion -like 'ffmpeg version 8.1.2*'
    $ffprobeOutput = & $ffprobePath -version 2>$null
    $ffprobeExit = $LASTEXITCODE
    $ffprobeVersion = $ffprobeOutput | Select-Object -First 1
    $ffprobeOk = $ffprobeExit -eq 0 -and $ffprobeVersion -like 'ffprobe version 8.1.2*'
    $ffmpegReady = $ffmpegOk -and $ffprobeOk
    if ($ffmpegReady -and $ffmpegVersion -like '*full_build*') {
        $ffmpegPackage = '8.1.2-full_build'
    }
}
if (-not $ffmpegReady) {
    Write-Host 'Descargando FFmpeg 8.1.2 essentials...'
    $ffmpegPackage = '8.1.2-essentials_build'
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
    foreach ($tool in @('ffmpeg', 'ffprobe')) {
        $binary = Get-ChildItem `
            -LiteralPath $ffmpegExpanded `
            -Recurse `
            -File `
            -Filter "$tool.exe" |
            Select-Object -First 1
        if ($null -eq $binary) {
            throw "El paquete de FFmpeg no contiene $tool.exe."
        }
        Copy-Item `
            -LiteralPath $binary.FullName `
            -Destination (Join-Path $runtimeDirectory "$tool.exe") `
            -Force
    }
} else {
    Write-Host 'FFmpeg y FFprobe 8.1.2 ya están preparados.'
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
