# Source code and build instructions

The submitted `Mafia-III-DE-Weapon-Flashlight.zip` contains a game executable with the keybind included, a modified `scripts.sds`, and a PowerShell keybind script. The modified archive has SHA-256 `8CCE3DAB6B865FD75E06F3D6F443C43555B6275E88FE382D16CB2E983FC9AA99` and matches this project's `scripts-flashlight-game-run-release.sds` build artifact.

## Build prerequisites

- Windows PowerShell 7
- Mafia Toolkit 2.36 for Windows x64, extracted so `MafiaToolkit.dll` is available
- The original `sds_retail/tables/scripts.sds` from a game installation

The builder reads the original archive and writes a separate output archive. It does not build the game executable.

## Build process

The build runs under PowerShell 7 from the source directory. It accepts paths to the original archive, the extracted Toolkit directory, and the output archive. A representative invocation is:

```powershell
$stock = 'C:\Program Files (x86)\Steam\steamapps\common\Mafia III\sds_retail\tables\scripts.sds'
$toolkit = 'C:\Modding\MafiaToolkit-2.36'
$output = 'C:\Modding\scripts.sds'
./Build-UploadedRelease.ps1 -StockArchive $stock -ToolkitPath $toolkit -OutputArchive $output
```

The build extracts the stock script bundle, generates a replacement Lua chunk, and serializes the modified SDS archive with Mafia Toolkit. It compares the output SHA-256 with the archive in the submitted ZIP and reports a mismatch if the hashes differ.

The PowerShell key binding source is in `Keybind/Set-FlashlightNativeBinding.ps1`. It edits a saved controls profile to bind B to the game's `AWARENESS` action. The archive build uses `analysis/Build-FlashlightPrototype.ps1` and `analysis/Build-MafiaScriptArchive.ps1`.

## Included source

- `Build-UploadedRelease.ps1` extracts the stock game script bundle with Mafia Toolkit and builds the uploaded mod archive.
- `analysis/` contains the archive and bytecode generation and parsing scripts used by the build.
- `Keybind/Set-FlashlightNativeBinding.ps1` contains the optional saved-controls binding source.

No compiled game executable is included in this source bundle.
