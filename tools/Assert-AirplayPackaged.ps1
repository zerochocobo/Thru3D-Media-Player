param([Parameter(Mandatory=$true)][string]$ArchivePath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ArchivePath))
try {
    $nativeRoot = if ([IO.Path]::GetExtension($ArchivePath) -eq '.aar') { 'jni' } else { 'lib' }
    $required = @("$nativeRoot/arm64-v8a/libquest_airplay.so", 'assets/airplay/NOTICE.txt',
        'assets/airplay/UxPlay-LICENSE.txt', 'assets/airplay/android-airplay-server-LICENSE.txt',
        'assets/airplay/OpenSSL-LICENSE.txt', 'assets/airplay/libplist-LICENSE.txt',
        'assets/airplay/llhttp-LICENSE.txt', 'assets/airplay/playfair-LICENSE.txt')
    foreach ($name in $required) {
        $entry = $archive.GetEntry($name)
        if ($null -eq $entry -or $entry.Length -eq 0) { throw "AirPlay packaged input missing: $name" }
    }
} finally { $archive.Dispose() }
Write-Output 'AirPlay receiver and source notices packaged.'
