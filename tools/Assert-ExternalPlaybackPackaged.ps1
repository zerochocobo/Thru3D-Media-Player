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
# Validate complete filters, not tokens scattered across unrelated filters. In particular,
# network playback must survive Android's MATCH_DEFAULT_ONLY domain preference filtering.
$filters = [regex]::Matches($block, '(?m)^(?<indent> *)E: intent-filter\b[^\r\n]*(?:\r?\n(?!\k<indent>E: )[^\r\n]*)*')
foreach ($scheme in @('file', 'content', 'http', 'https')) {
    foreach ($mime in @('video/*', 'application/vnd.apple.mpegurl', 'application/x-mpegURL')) {
        $required = @('android.intent.action.VIEW', 'android.intent.category.DEFAULT', $scheme, $mime)
        if ($scheme -in @('http', 'https')) { $required += 'android.intent.category.BROWSABLE' }
        $found = $false
        foreach ($filter in $filters) {
            $missing = @($required | Where-Object { -not $filter.Value.Contains('="' + $_ + '"') })
            if ($missing.Count -eq 0) { $found = $true; break }
        }
        if (-not $found) { throw "APK external video filter is incomplete: $scheme $mime (network requires BROWSABLE)." }
    }
}
