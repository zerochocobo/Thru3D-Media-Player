param([string]$Ffmpeg = 'ffmpeg')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$destination = Join-Path $workspace 'build/output/cinema-prototype'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
# Original synthetic motion signal, with no downloaded footage or audio.
$filter = "nullsrc=s=960x540:r=24,geq=r='32+45*(0.5+0.5*sin(X/180+T/2))+90*exp(-pow((Y-H*0.52-45*sin(X/230+T/3))/80,2))':g='38+75*(0.5+0.5*sin(X/220+Y/160+T/3))':b='60+80*(0.5+0.5*sin(Y/180+X/290-T/4))',format=yuv420p,drawbox=x=0:y=0:w=96:h=54:color=0xE0B85A:t=fill"
# All-intra also avoids malformed interframes from the local libtheora build.
& $Ffmpeg -hide_banner -loglevel error -y -f lavfi -i $filter -t 8 -pix_fmt yuv420p -c:v libtheora -g 1 -q:v 7 -an (Join-Path $destination 'cinema-motion.ogv')
if ($LASTEXITCODE -ne 0) { throw 'Could not create the cinema motion clip' }
& $Ffmpeg -hide_banner -loglevel error -xerror -i (Join-Path $destination 'cinema-motion.ogv') -f null -
if ($LASTEXITCODE -ne 0) { throw 'Cinema motion clip decode validation failed' }
Write-Output (Join-Path $destination 'cinema-motion.ogv')
