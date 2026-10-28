$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$output = Join-Path $workspace 'build/output/music-formats/fixtures'
New-Item -ItemType Directory -Force $output | Out-Null
& ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'sine=frequency=440:sample_rate=96000:duration=6' -af 'pan=stereo|c0=c0|c1=c0,volume=0.05' -c:a flac -sample_fmt s32 (Join-Path $output 'stereo.flac')
if ($LASTEXITCODE) { throw 'FLAC stereo fixture failed' }
& ffmpeg -hide_banner -loglevel error -y -i (Join-Path $output 'stereo.flac') -ar 48000 -c:a aac -b:a 128k (Join-Path $output 'aac.m4a')
if ($LASTEXITCODE) { throw 'AAC M4A fixture failed' }
& ffmpeg -hide_banner -loglevel error -y -i (Join-Path $output 'stereo.flac') -ar 44100 -c:a alac (Join-Path $output 'alac.m4a')
if ($LASTEXITCODE) { throw 'ALAC M4A fixture failed' }
& ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'aevalsrc=0.01*sin(2*PI*220*t)|0.01*sin(2*PI*330*t)|0.01*sin(2*PI*440*t)|0.01*sin(2*PI*55*t)|0.01*sin(2*PI*550*t)|0.01*sin(2*PI*660*t):s=48000:d=6:c=5.1' -c:a flac (Join-Path $output 'surround.flac')
if ($LASTEXITCODE) { throw 'FLAC surround fixture failed' }
& ffmpeg -hide_banner -loglevel error -y -i (Join-Path $output 'surround.flac') -c:a dca -strict -2 -b:a 1411200 (Join-Path $output 'surround.dts')
if ($LASTEXITCODE) { throw 'DTS fixture failed' }
& ffmpeg -hide_banner -loglevel error -y -i (Join-Path $output 'surround.dts') -c:a copy (Join-Path $output 'dts.wav')
if ($LASTEXITCODE) { throw 'DTS-WAV fixture failed' }
Set-Content (Join-Path $output 'invalid.flac') 'synthetic invalid audio'
Write-Output "Synthetic music fixtures: $output"
