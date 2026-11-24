param(
    [Parameter(Mandatory)]
    [string]$BundlePath,

    [Parameter(Mandatory)]
    [string]$ScriptPath,

    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$bundle = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $BundlePath).Path)
$data = [Text.Encoding]::Latin1.GetString($bundle)
if ($ScriptPath -cnotmatch '^/scripts/[a-zA-Z0-9_!./-]+\.lua$') {
    throw 'Specify an internal /scripts/... path with a .lua suffix. This reader handles the observed 32-bit length prefix.'
}

$position = $data.IndexOf($ScriptPath, [StringComparison]::Ordinal)
$matches = @(
    while ($position -ge 0) {
        $pathEnd = $position + $ScriptPath.Length
        if ($position -ge 18 -and $pathEnd + 10 -le $bundle.Length -and
            [BitConverter]::ToUInt16($bundle, $position - 2) -eq $ScriptPath.Length -and
            [Convert]::ToHexString($bundle, $pathEnd + 4, 6) -eq '1B4C7561510E') {
            $size = [BitConverter]::ToUInt32($bundle, $pathEnd)
            if ($size -ge 12 -and $size -le $bundle.Length - ($pathEnd + 4)) {
                [pscustomobject]@{
                    Script = $ScriptPath
                    Offset = $pathEnd + 4
                    Length = $size
                    Signature = '1B4C7561510E'
                }
            }
        }
        $position = $data.IndexOf($ScriptPath, $position + 1, [StringComparison]::Ordinal)
    }
)

if ($matches.Count -ne 1) {
    throw "Expected exactly one length-prefixed format-14 Lua chunk for $ScriptPath. Found $($matches.Count)."
}

$entry = $matches[0]
if ($OutputPath) {
    $destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $stream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew)
    try {
        $stream.Write($bundle, $entry.Offset, [int]$entry.Length)
    }
    finally {
        $stream.Dispose()
    }
}
$entry
