[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StockArchive,
    [Parameter(Mandatory)][string]$ToolkitPath,
    [Parameter(Mandatory)][string]$OutputArchive
)

$ErrorActionPreference = 'Stop'
$stock = (Resolve-Path -LiteralPath $StockArchive).Path
$toolkit = (Resolve-Path -LiteralPath $ToolkitPath).Path
$output = [IO.Path]::GetFullPath($OutputArchive)
$temp = Join-Path ([IO.Path]::GetTempPath()) ('mafia-flashlight-build-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)

try {
    [Reflection.Assembly]::LoadFrom((Join-Path $toolkit 'MafiaToolkit.dll')) | Out-Null
    $gameType = [Utils.Settings.GamesEnumerator]::MafiaIII
    [Utils.Settings.GameStorage]::Instance.SetSelectedGame(
        [Utils.Settings.Game]::new('Mafia III', '', '', '', '', $gameType))
    $archive = [Gibbed.Mafia2.FileFormats.ArchiveFile]::new()
    $archive.SetGameType($gameType)
    $stream = [IO.File]::OpenRead($stock)
    try { $archive.Deserialize($stream) }
    finally { $stream.Dispose() }
    if ($archive.ResourceEntries.Count -ne 1) {
        throw 'Expected one script bundle in the stock scripts.sds archive.'
    }

    $bundlePath = Join-Path $temp 'scripts.bin'
    $chunkPath = Join-Path $temp 'threads.luac'
    [IO.File]::WriteAllBytes($bundlePath, $archive.ResourceEntries[0].Data)
    & (Join-Path $PSScriptRoot 'analysis/Build-FlashlightPrototype.ps1') `
        -BundlePath $bundlePath -OutputChunk $chunkPath `
        -NativeKeyboardAction AWARENESS -TagPlayerForWeaponLight `
        -RecoverAfterRespawn -StartOnGameRun | Out-Null
    & (Join-Path $PSScriptRoot 'analysis/Build-MafiaScriptArchive.ps1') `
        -ToolkitPath $toolkit -SourceArchive $stock -OutputArchive $output `
        -ScriptPath /scripts/common/base/threads.lua -ReplacementChunk $chunkPath | Out-Null

    $actualHash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
    $expectedHash = '8CCE3DAB6B865FD75E06F3D6F443C43555B6275E88FE382D16CB2E983FC9AA99'
    if ($actualHash -cne $expectedHash) {
        throw "Build completed but did not match the uploaded archive. SHA-256: $actualHash"
    }
    Write-Output "Reproduced uploaded scripts.sds. SHA-256: $actualHash"
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
