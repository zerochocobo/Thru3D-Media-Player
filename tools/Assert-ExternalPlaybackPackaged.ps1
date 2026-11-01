param([Parameter(Mandatory)][string]$ManifestText)
$ErrorActionPreference = 'Stop'
# aapt2 xmltree indents component children. Check the actual APK for every build type/channel.
$lines = $ManifestText -split "`n"
$name = @($lines | Select-String 'android:name[^\r\n]*="org\.vrpassthroughplayer\.plugin\.ExternalPlaybackActivity"')
if ($name.Count -ne 1) { throw 'APK must have exactly one production external video activity.' }
$start = $name[0].LineNumber - 1
while ($start -ge 0 -and $lines[$start] -notmatch '^([ ]*)E: activity\b') { $start-- }
if ($start -lt 0) { throw 'APK external video entry is not an Activity.' }
$indent = [regex]::Match($lines[$start], '^ *').Length
$end = $start + 1
while ($end -lt $lines.Count) {
    if ($lines[$end] -match '^([ ]*)E: ' -and $Matches[1].Length -le $indent) { break }
    $end++
}
$block = $lines[$start..($end - 1)] -join "`n"
if ($block -notmatch 'android:exported[^\r\n]*=true' -or $block -match 'android:enabled[^\r\n]*=false') {
    throw 'APK external video entry is not enabled and exported.'
}
foreach ($value in @('android.intent.action.VIEW', 'android.intent.category.DEFAULT', 'video/*', 'file', 'content', 'http', 'https')) {
    if (-not $block.Contains('="' + $value + '"')) { throw "APK external video association is missing: $value" }
}
