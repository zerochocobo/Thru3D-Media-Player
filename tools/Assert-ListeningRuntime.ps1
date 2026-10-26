param(
    [Parameter(Mandatory)][string]$LibraryPath,
    [string]$RuntimePath = '',
    [string]$NdkRoot = $env:ANDROID_NDK_HOME
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $RuntimePath) { $RuntimePath = Join-Path $root 'tmp/narration-deps/libonnxruntime.so' }
if (-not $NdkRoot) { throw 'Activate the pinned Android toolchain first.' }
$ort = Get-Content (Join-Path $root 'third_party/narration/dependencies.json') -Raw | ConvertFrom-Json
if ((Get-FileHash -LiteralPath $RuntimePath).Hash.ToLowerInvariant() -ne $ort.runtime_library.sha256) {
    throw 'Listening must use the existing pinned full ONNX Runtime; replacement is forbidden.'
}
$readelf = Join-Path $NdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-readelf.exe'
$required = (& $readelf --dyn-syms --wide $LibraryPath | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect Moonshine ELF symbols.' }
$provided = (& $readelf --dyn-syms --wide $RuntimePath | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect ONNX Runtime ELF symbols.' }
$bindings = @([regex]::Matches($required, '\bUND\s+(Ort\w+)@(VERS_[\d.]+)') | ForEach-Object {
    $symbol = $_.Groups[1].Value; $version = $_.Groups[2].Value
    if ($provided -notmatch ('\b' + [regex]::Escape($symbol + '@@' + $version) + '(\s|$)')) {
        throw "Moonshine requires an unavailable ONNX symbol: $symbol@$version"
    }
    "$symbol@$version"
})
if ($bindings -notcontains "OrtGetApiBase@VERS_$($ort.onnxruntime_version)") { throw 'Moonshine ONNX API binding is missing or unversioned.' }
$segments = (& $readelf --program-headers --wide $LibraryPath | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect Moonshine ELF segments.' }
$loads = @($segments -split '\r?\n' | Where-Object { $_ -match '^\s*LOAD\s' })
if (-not $loads -or @($loads | Where-Object { $_ -notmatch '\s0x4000\s*$' }).Count) { throw 'Moonshine requires 16 KB LOAD alignment.' }
[pscustomobject]@{
    bytes = (Get-Item -LiteralPath $LibraryPath).Length
    sha256 = (Get-FileHash -LiteralPath $LibraryPath).Hash.ToLowerInvariant()
    ort_sha256 = $ort.runtime_library.sha256
    bindings = $bindings
}
