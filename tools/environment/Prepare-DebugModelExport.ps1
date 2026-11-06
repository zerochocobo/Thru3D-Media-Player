param([Parameter(Mandatory=$true)][string]$PresetsPath)
$ErrorActionPreference = 'Stop'
$presetText = [IO.File]::ReadAllText($PresetsPath)
$filterPattern = '(?m)^exclude_filter="([^"]*)"'
if (-not [regex]::IsMatch($presetText, $filterPattern)) { throw 'Export presets have no exclusion filters.' }
# Godot can convert GDScript and emit its remap before our export plugin's
# skip() callback. Exclude the source directory before resource conversion too.
$modelPresets = [regex]::Replace($presetText, $filterPattern, [Text.RegularExpressions.MatchEvaluator]{
    param($filterMatch)
    $modelFilters = @($filterMatch.Groups[1].Value.Split(',') | Where-Object { $_ })
    if ('environments/private_beach/*' -notin $modelFilters) { $modelFilters += 'environments/private_beach/*' }
    return 'exclude_filter="' + ($modelFilters -join ',') + '"'
})
[IO.File]::WriteAllText($PresetsPath, $modelPresets, [Text.UTF8Encoding]::new($false))
