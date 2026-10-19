param([string]$Ffmpeg = 'ffmpeg')
$ErrorActionPreference = 'Stop'
$clipDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'build/output/cinema-desktop-video/samples'
New-Item -ItemType Directory -Path $clipDirectory -Force | Out-Null
$mp4 = Join-Path $clipDirectory 'synthetic-audio.mp4'
& $Ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc=size=320x180:rate=24' -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 4 -c:v libx264 -pix_fmt yuv420p -c:a aac -af 'volume=0.03' -shortest $mp4
if ($LASTEXITCODE -ne 0) { throw 'Synthetic MP4 generation failed' }
& $Ffmpeg -hide_banner -loglevel error -y -i $mp4 -c copy (Join-Path $clipDirectory 'synthetic-audio.mkv')
if ($LASTEXITCODE -ne 0) { throw 'Synthetic MKV generation failed' }
& $Ffmpeg -hide_banner -loglevel error -y -i $mp4 -c:v libtheora -g 1 -q:v 7 -pix_fmt yuv420p -c:a libvorbis (Join-Path $clipDirectory 'synthetic-audio.ogv')
if ($LASTEXITCODE -ne 0) { throw 'Synthetic OGV generation failed' }
& $Ffmpeg -hide_banner -loglevel error -y -i $mp4 -vn -c:a pcm_s16le (Join-Path $clipDirectory 'synthetic-audio-only.wav')
if ($LASTEXITCODE -ne 0) { throw 'Synthetic audio-only generation failed' }
[System.IO.File]::WriteAllBytes((Join-Path $clipDirectory 'synthetic-corrupt.mp4'), [byte[]]::new(256))
$captions = Join-Path $clipDirectory 'synthetic-captions.srt'
[System.IO.File]::WriteAllText($captions, "1`n00:00:00,000 --> 00:00:03,000`nSynthetic caption`n", [System.Text.UTF8Encoding]::new($false))
& $Ffmpeg -hide_banner -loglevel error -y -i $mp4 -i $captions -map '0:v:0' -map '1:0' -c:v copy -c:s srt -an (Join-Path $clipDirectory 'synthetic-silent-subtitle.mkv')
if ($LASTEXITCODE -ne 0) { throw 'Synthetic silent/subtitle generation failed' }
foreach ($clipName in @('synthetic-audio.mp4','synthetic-audio.mkv','synthetic-audio.ogv','synthetic-audio-only.wav','synthetic-silent-subtitle.mkv')) {
    $decodeArguments = @('-nostdin', '-hide_banner', '-loglevel', 'error', '-xerror', '-i', (Join-Path $clipDirectory $clipName))
    if ($clipName -notlike '*.wav') { $decodeArguments += @('-r', '24', '-fps_mode', 'cfr') }
    & $Ffmpeg @decodeArguments -f null -
    if ($LASTEXITCODE -ne 0) { throw "Synthetic fixture decode failed: $clipName" }
}
Write-Output $clipDirectory
