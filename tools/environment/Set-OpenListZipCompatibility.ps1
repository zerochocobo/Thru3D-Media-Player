param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Go,
    [Parameter(Mandatory)][string]$ModuleCache
)
$ErrorActionPreference = 'Stop'
# Keep the pinned AES/ZipCrypto implementation; fix ZIP64's conditional fields.
# Regenerate a private module copy, never modify Go's shared module cache.
$upstream = Join-Path $ModuleCache 'github.com/!kir!cute/zip@v1.0.1'
$reader = Join-Path $upstream 'reader.go'
if (!(Test-Path -LiteralPath $reader) -or
    (Get-FileHash -LiteralPath $reader -Algorithm SHA256).Hash -ne '2ED444AA520C701965C4C7D0D8EBF758946C5A4A997F73EEADC1114D95398FB8') {
    throw 'Pinned ZIP reader missing or changed; review the ZIP64 compatibility patch.'
}
$text = [IO.File]::ReadAllText($reader).Replace("`r`n", "`n")
$begin = $text.IndexOf("`t`t`tcase zip64ExtraId:", [StringComparison]::Ordinal)
$end = $text.IndexOf("`t`t`tcase winzipAesExtraId:", [StringComparison]::Ordinal)
if ($begin -lt 0 -or $end -le $begin) { throw 'ZIP64 compatibility patch target missing.' }
$replacement = @'
			case zip64ExtraId:
				// ZIP64 values are present only for corresponding sentinel fields.
				// An offset-only record must not replace the uncompressed size.
				if f.UncompressedSize == ^uint32(0) {
					if len(eb) < 8 { return ErrFormat }
					f.UncompressedSize64 = eb.uint64()
				}
				if f.CompressedSize == ^uint32(0) {
					if len(eb) < 8 { return ErrFormat }
					f.CompressedSize64 = eb.uint64()
				}
				if f.headerOffset == int64(^uint32(0)) {
					if len(eb) < 8 { return ErrFormat }
					f.headerOffset = int64(eb.uint64())
				}
				if f.diskNb == int32(^uint16(0)) {
					if len(eb) < 4 { return ErrFormat }
					f.diskNb = int32(eb.uint32())
				}
'@
$patched = $text.Substring(0, $begin) + $replacement.Replace("`r`n", "`n") + "`n" + $text.Substring($end)
$destination = Join-Path $Source 'vrpp_zip'
New-Item -ItemType Directory -Force -Path $destination | Out-Null
Get-ChildItem -LiteralPath $upstream -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $destination $_.Name) -Force
}
$patchedReader = Join-Path $destination 'reader.go'
(Get-Item -LiteralPath $patchedReader).IsReadOnly = $false
[IO.File]::WriteAllText($patchedReader, $patched, [Text.UTF8Encoding]::new($false))
& $Go -C $Source mod edit '-require=github.com/KirCute/zip@v1.0.1' '-replace=github.com/KirCute/zip=./vrpp_zip'
if ($LASTEXITCODE) { throw 'Could not select the ZIP64 compatibility module.' }
