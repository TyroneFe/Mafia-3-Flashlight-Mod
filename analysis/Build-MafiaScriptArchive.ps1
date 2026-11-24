[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolkitPath,
    [Parameter(Mandatory)][string]$SourceArchive,
    [Parameter(Mandatory)][string]$OutputArchive,
    [string]$ScriptPath,
    [string]$ReplacementChunk
)

$ErrorActionPreference = 'Stop'
if ([bool]$ScriptPath -ne [bool]$ReplacementChunk) {
    throw 'Specify ScriptPath and ReplacementChunk together.'
}
$source = (Resolve-Path -LiteralPath $SourceArchive).Path
$output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputArchive)
if (Test-Path -LiteralPath $output) { throw "Output already exists: $output" }

$dll = Join-Path (Resolve-Path -LiteralPath $ToolkitPath).Path 'MafiaToolkit.dll'
[Reflection.Assembly]::LoadFrom($dll) | Out-Null
$gameType = [Utils.Settings.GamesEnumerator]::MafiaIII
[Utils.Settings.GameStorage]::Instance.SetSelectedGame(
    [Utils.Settings.Game]::new('Mafia III', '', '', '', '', $gameType))

function Read-Archive([string]$Path) {
    $archive = [Gibbed.Mafia2.FileFormats.ArchiveFile]::new()
    $archive.SetGameType($gameType)
    $stream = [IO.File]::OpenRead($Path)
    try { $archive.Deserialize($stream) }
    finally { $stream.Dispose() }
    if ($archive.Version -ne 20 -or $archive.ResourceEntries.Count -ne 1 -or
        $archive.ResourceTypes.Count -ne 1 -or $archive.ResourceTypes[0].Name -ne 'Script' -or
        $archive.ResourceEntries[0].Version -ne 4 -or $archive.ResourceEntries[0].TypeId -ne 0) {
        throw "Unsupported scripts archive: $Path"
    }
    $archive
}

function Get-ScriptRecords([byte[]]$Bytes) {
    $latin = [Text.Encoding]::Latin1
    if ($Bytes.Length -lt 30 -or [BitConverter]::ToUInt16($Bytes) -ne 24 -or
        $latin.GetString($Bytes, 2, 24) -cne '/scripts/common/startup/') {
        throw 'Unsupported script bundle header.'
    }
    $count = [BitConverter]::ToUInt32($Bytes, 26)
    $position = 30
    for ($i = 0; $i -lt $count; $i++) {
        if ($position + 22 -gt $Bytes.Length) { throw "Truncated record $i." }
        $pathLength = [BitConverter]::ToUInt16($Bytes, $position + 16)
        $lengthOffset = $position + 18 + $pathLength
        if ($lengthOffset + 4 -gt $Bytes.Length) { throw "Truncated path at record $i." }
        $name = $latin.GetString($Bytes, $position + 18, $pathLength)
        $length = [BitConverter]::ToUInt32($Bytes, $lengthOffset)
        $chunkOffset = $lengthOffset + 4
        if ($length -lt 14 -or $length -gt $Bytes.Length - $chunkOffset -or
            [Convert]::ToHexString($Bytes, $chunkOffset, 6) -ne '1B4C7561510E') {
            throw "Unsupported Lua chunk at record $i."
        }
        [pscustomobject]@{ Path = $name; Offset = $chunkOffset; Length = $length }
        $position = $chunkOffset + [int]$length
    }
    if ($position -ne $Bytes.Length) { throw 'Trailing bytes in script bundle.' }
}

$archive = Read-Archive $source
$entry = $archive.ResourceEntries[0]
$payload = $entry.Data
$records = @(Get-ScriptRecords $payload)
if ($ReplacementChunk) {
    $target = @($records | Where-Object Path -CEQ $ScriptPath)
    if ($target.Count -ne 1) { throw "Expected one script record for $ScriptPath." }
    $target = $target[0]
    $replacement = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $ReplacementChunk).Path)
    if ($replacement.Length -lt 14 -or [Convert]::ToHexString($replacement, 0, 14) -ne
        [Convert]::ToHexString($payload, $target.Offset, 14)) {
        throw 'Replacement chunk header differs from the original.'
    }
    if ($replacement.Length -ne $target.Length) {
        throw 'A different chunk length requires recalculating the SDS script memory budget.'
    }
    $payload = [byte[]]$payload.Clone()
    [Array]::Copy($replacement, 0, $payload, $target.Offset, $target.Length)
    $entry.Data = $payload
}

# Reopen the staged archive and compare its script data before moving it into place.
$staged = Join-Path ([IO.Path]::GetDirectoryName($output)) ('.scripts-' + [guid]::NewGuid() + '.sds')
$stagedCreated = $false
try {
    $stream = [IO.File]::Open($staged, [IO.FileMode]::CreateNew)
    $stagedCreated = $true
    try { $archive.Serialize($stream, [Gibbed.Mafia2.FileFormats.ArchiveSerializeOptions]::None) }
    finally { $stream.Dispose() }
    $reopened = Read-Archive $staged
    $actual = $reopened.ResourceEntries[0]
    if ($reopened.Platform -ne $archive.Platform -or $reopened.Endian -ne $archive.Endian -or
        $reopened.SlotRamRequired -ne $archive.SlotRamRequired -or
        $reopened.OtherRamRequired -ne $archive.OtherRamRequired -or
        $reopened.SlotVramRequired -ne $archive.SlotVramRequired -or
        $reopened.OtherVramRequired -ne $archive.OtherVramRequired -or
        $actual.FileHash -ne $entry.FileHash -or
        $actual.SlotRamRequired -ne $entry.SlotRamRequired -or $actual.OtherRamRequired -ne $entry.OtherRamRequired -or
        $actual.SlotVramRequired -ne $entry.SlotVramRequired -or $actual.OtherVramRequired -ne $entry.OtherVramRequired -or
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($actual.Data)) -ne
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payload))) {
        throw 'Reopened archive does not contain the expected script resource.'
    }
    [IO.File]::Move($staged, $output)
}
finally {
    if ($stagedCreated) { [IO.File]::Delete($staged) }
}
[pscustomobject]@{ Archive = $output; Scripts = $records.Count; Replaced = $ScriptPath; PayloadBytes = $payload.Length }
