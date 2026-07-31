[CmdletBinding()]
param(
    [switch]$SkipWindows,
    [switch]$SkipAndroid
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$flutterApp = Join-Path $workspace 'apps\bit_share_flutter'
$keyRoot = Join-Path $env:USERPROFILE 'Documents\BitStation\ReleaseKeys\Bit-Share'
$secretFile = Join-Path $keyRoot 'bit-share-release.password.dpapi'
$keyProperties = Join-Path $flutterApp 'android\key.properties'

# pubspec.yaml is the single source of truth for the version: both builds
# and the Windows installer are stamped with it via --dart-define /DAppVersion
# so the in-app updater (lib/features/update) always compares against the
# version that was actually shipped.
$pubspec = Get-Content -LiteralPath (Join-Path $flutterApp 'pubspec.yaml') -Raw
if ($pubspec -notmatch 'version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
    throw 'No se pudo leer la versión desde pubspec.yaml.'
}
$appVersion = $Matches[1]
Write-Host "Versión: $appVersion" -ForegroundColor Cyan

function Get-ReleasePassword {
    if (-not (Test-Path -LiteralPath $secretFile)) {
        throw "No se encontró el respaldo cifrado de la llave: $secretFile"
    }
    $secure = Get-Content -LiteralPath $secretFile | ConvertTo-SecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

Push-Location $flutterApp
try {
    flutter pub get

    if (-not $SkipAndroid) {
        if (-not (Test-Path -LiteralPath $keyProperties)) {
            throw "No se encontró la configuración local de firma: $keyProperties"
        }
        $releasePassword = Get-ReleasePassword
        $env:BITSHARE_STORE_PASSWORD = $releasePassword
        $env:BITSHARE_KEY_PASSWORD = $releasePassword
        flutter build apk --release --dart-define=APP_VERSION=$appVersion
        Remove-Item Env:BITSHARE_STORE_PASSWORD -ErrorAction SilentlyContinue
        Remove-Item Env:BITSHARE_KEY_PASSWORD -ErrorAction SilentlyContinue
    }

    if (-not $SkipWindows) {
        & (Join-Path $workspace 'tools\setup_windows_runtime.ps1')
        flutter build windows --release --dart-define=APP_VERSION=$appVersion
        & 'C:\Users\BitSt\AppData\Local\Programs\Antigravity IDE\resources\app\node_modules\innosetup\bin\ISCC.exe' "/DAppVersion=$appVersion" (Join-Path $workspace 'tools\installer\bit-share.iss')
    }
}
finally {
    Pop-Location
    Remove-Item Env:BITSHARE_STORE_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:BITSHARE_KEY_PASSWORD -ErrorAction SilentlyContinue
}
