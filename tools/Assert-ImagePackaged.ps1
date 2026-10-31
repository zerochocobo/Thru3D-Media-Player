param([Parameter(Mandatory=$true)][string]$ArchivePath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($ArchivePath)
try {
    $apk=$ArchivePath.EndsWith('.apk',[StringComparison]::OrdinalIgnoreCase)
    $native=if($apk){'lib/arm64-v8a/'}else{'jni/arm64-v8a/'}
    $assets=if($apk){'assets/'}else{'assets/'}
    foreach($library in @('libquest_image.so','libavcodec.so','libavformat.so','libavutil.so','libswscale.so')) {
        $entry=$zip.GetEntry($native+$library)
        if(!$entry -or $entry.Length -le 0){throw "Image decoder package missing: $library"}
    }
    foreach($name in @('libavif-LICENSE.txt','libraw-COPYRIGHT.txt','libraw-LICENSE.LGPL.txt','libraw-LICENSE.CDDL.txt','libwebp-COPYING.txt','libwebp-PATENTS.txt','lcms-LICENSE.txt')) {
        $entry=$zip.GetEntry($assets+'image/'+$name)
        if(!$entry -or $entry.Length -le 0){throw "Image decoder license missing: $name"}
    }
    if(@($zip.Entries|Where-Object {$_.FullName -match '^assets/image/.*\.tar\.'}).Count){throw 'Image dependency sources must not be packaged as runtime assets.'}
    if(!$apk){
        $entry=$zip.GetEntry('proguard.txt')
        if(!$entry){throw 'Image JNI keep rules missing.'}
        $reader=[IO.StreamReader]::new($entry.Open())
        try{$rules=$reader.ReadToEnd()}finally{$reader.Dispose()}
        if(!$rules.Contains('-keep class org.vrpassthroughplayer.plugin.ExtendedImageNative')){throw 'Image JNI class must survive Release shrinking.'}
    }
    if($apk) {
        $entry=$zip.GetEntry('assets/scripts/photo_animation.gd.remap')
        if(!$entry){throw 'Photo animation script remap missing.'}
        $reader=[IO.StreamReader]::new($entry.Open())
        try{$mapping=$reader.ReadToEnd()}finally{$reader.Dispose()}
        $match=[regex]::Match($mapping,'path="res://([^"]+)"')
        if(!$match.Success -or !$zip.GetEntry('assets/'+$match.Groups[1].Value)){throw 'Compiled photo animation script missing.'}
    }
    Write-Output 'Image decoder package verified: native decoder, FFmpeg, licenses and source exclusions.'
}finally{$zip.Dispose()}
