param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache/thru3d-toolchain' }))
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $env:ANDROID_NDK_HOME) { . "$PSScriptRoot/Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot }
$manifestPath = Join-Path $root 'third_party/moonshine/model.json'
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$ort = Get-Content (Join-Path $root 'third_party/narration/dependencies.json') -Raw | ConvertFrom-Json
$runtime = Join-Path $root 'tmp/narration-deps/libonnxruntime.so'
if ($manifest.library.build -ne 'source' -or $manifest.library.onnxruntime_version -ne $ort.onnxruntime_version) { throw 'Unreviewed listening runtime configuration.' }
if ((Get-FileHash -LiteralPath $runtime).Hash.ToLowerInvariant() -ne $ort.runtime_library.sha256) { throw 'Prepare the pinned narration runtime first; do not replace it for listening.' }
$source = Join-Path $root 'tmp/moonshine-runtime-source'
$build = Join-Path $root 'build/listening-runtime'
$logs = Join-Path $root 'build/output/logs'
New-Item -ItemType Directory -Force $build, $logs | Out-Null
$oldLfs = $env:GIT_LFS_SKIP_SMUDGE
$verifiedInputs = @{ 'core/third-party/onnxruntime/lib/android/arm64/libonnxruntime.so' = $ort.runtime_library.sha256 }
try {
    $env:GIT_LFS_SKIP_SMUDGE = '1'
    if (-not (Test-Path -LiteralPath (Join-Path $source '.git'))) {
        & git clone --filter=blob:none --no-checkout --depth 1 --branch "v$($manifest.version)" $manifest.source.repository $source
        if ($LASTEXITCODE -ne 0) { throw 'Moonshine source checkout failed.' }
    }
    $revision = (& git -C $source rev-parse HEAD | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $revision -ne $manifest.revision) { throw 'Moonshine source revision differs from the reviewed pin.' }
    & git -C $source sparse-checkout set --no-cone '/core/*' '!/core/third-party/onnxruntime/lib/' '!/core/third-party/onnxruntime/lib-static/' '!/core/moonshine-tts/data/' '/language-bindings/android/moonshine-jni/' '/LICENSE' '/.gitattributes'
    if ($LASTEXITCODE -ne 0) { throw 'Moonshine sparse source preparation failed.' }
    # Fetch just the two compiled LFS objects. `git lfs pull` enumerates all blob
    # sizes and defeats the sparse/partial clone by fetching unrelated model trees.
    foreach ($relative in @('core/moonshine-tts/src/zipvoice-voices-data.cpp', 'core/cpp-annote/src/community1_cpp_annote_embedded.cpp')) {
        $pointer = (& git -C $source show "HEAD:$relative" | Out-String)
        if ($LASTEXITCODE -ne 0 -or $pointer -notmatch 'oid sha256:([a-f0-9]{64})') { throw 'Missing pinned LFS source digest.' }
        $sha = $Matches[1]
        $cached = Join-Path $root "tmp/live-interpretation/$sha.cpp"
        & "$PSScriptRoot/Download-Artifact.ps1" -Uri "https://media.githubusercontent.com/media/moonshine-ai/moonshine/$revision/$relative" -Destination $cached -Sha256 $sha
        $destination = Join-Path $source $relative
        if ((Get-FileHash $destination).Hash.ToLowerInvariant() -ne $sha) { Copy-Item -LiteralPath $cached -Destination $destination }
        $verifiedInputs[$relative] = $sha
    }
    $patcher = Join-Path $root 'tools/moonshine/patch_runtime.py'
    $patchResult = & python $patcher $source
    if ($LASTEXITCODE -ne 0) { throw 'Moonshine lifetime patch verification failed.' }
    ($patchResult | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $verifiedInputs[$_.Name] = $_.Value }
    $dirty = @(& git -C $source status --porcelain --untracked-files=no)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot verify Moonshine pinned sources.' }
    foreach ($change in $dirty) {
        # Hosts without a global LFS clean filter report materialized objects as
        # modified. Accept only their pinned SHA256 and the intentional ORT input.
        $relative = $change.Substring(3)
        if (-not $change.StartsWith(' M ') -or -not $verifiedInputs.ContainsKey($relative) -or
            (Get-FileHash (Join-Path $source $relative)).Hash.ToLowerInvariant() -ne $verifiedInputs[$relative]) {
            throw 'Moonshine pinned source digest differs.'
        }
    }
} finally { $env:GIT_LFS_SKIP_SMUDGE = $oldLfs }
# Upstream CMake resolves this path internally. Supply our existing full runtime,
# never its bundled 1.23.2 library. Older C API headers are supported by ORT 1.28.
$linkRuntime = Join-Path $source 'core/third-party/onnxruntime/lib/android/arm64/libonnxruntime.so'
New-Item -ItemType Directory -Force (Split-Path -Parent $linkRuntime) | Out-Null
if (-not (Test-Path -LiteralPath $linkRuntime) -or (Get-FileHash $linkRuntime).Hash.ToLowerInvariant() -ne $ort.runtime_library.sha256) { Copy-Item -LiteralPath $runtime -Destination $linkRuntime }
$cmakeBin = Join-Path $env:ANDROID_HOME 'cmake/3.31.6/bin'
$cmake = Join-Path $cmakeBin 'cmake.exe'
& $cmake -S "$source/core" -B $build -G Ninja "-DCMAKE_MAKE_PROGRAM=$cmakeBin/ninja.exe" `
    "-DCMAKE_TOOLCHAIN_FILE=$env:ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" `
    '-DANDROID_ABI=arm64-v8a' '-DANDROID_PLATFORM=android-29' '-DANDROID_STL=c++_static' '-DCMAKE_BUILD_TYPE=Release' `
    '-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-z,max-page-size=16384' '-DMOONSHINE_TTS_BUILD_ONNX=ON' *> (Join-Path $logs 'listening-configure.log')
if ($LASTEXITCODE -ne 0) { throw 'Moonshine configure failed; inspect listening-configure.log.' }
# v0.1.5 C API unconditionally references its TTS implementation. Build the
# unchanged library; only ASR is called, and no Moonshine TTS models are packaged.
& $cmake --build $build --target moonshine --parallel 4 *> (Join-Path $logs 'listening-build.log')
if ($LASTEXITCODE -ne 0) { throw 'Moonshine source build failed; inspect listening-build.log.' }
$prepared = Join-Path $build 'packaged/libmoonshine.so'
New-Item -ItemType Directory -Force (Split-Path -Parent $prepared) | Out-Null
& "$env:ANDROID_NDK_HOME/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-strip.exe" --strip-unneeded -o $prepared (Join-Path $build 'libmoonshine.so')
if ($LASTEXITCODE -ne 0) { throw 'Moonshine strip failed.' }
$verified = & "$root/tools/Assert-ListeningRuntime.ps1" -LibraryPath $prepared
$library = Join-Path $root 'android/player-plugin/src/main/jniLibs/arm64-v8a/libmoonshine.so'
New-Item -ItemType Directory -Force (Split-Path -Parent $library) | Out-Null
if (-not (Test-Path -LiteralPath $library) -or (Get-FileHash $library).Hash.ToLowerInvariant() -ne $verified.sha256) { Copy-Item -LiteralPath $prepared -Destination $library }
@{
    revision = $manifest.revision
    manifest_sha256 = (Get-FileHash $manifestPath).Hash.ToLowerInvariant()
    builder_sha256 = (Get-FileHash $PSCommandPath).Hash.ToLowerInvariant()
    patcher_sha256 = (Get-FileHash $patcher).Hash.ToLowerInvariant()
    library = $verified
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $build 'receipt.json') -Encoding utf8
Write-Output 'Moonshine built against the unchanged pinned ONNX Runtime; ELF bindings verified.'
