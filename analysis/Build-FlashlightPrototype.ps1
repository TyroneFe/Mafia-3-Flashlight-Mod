param(
    [Parameter(Mandatory)][string]$BundlePath,
    [Parameter(Mandatory)][string]$OutputChunk,
    [ValidateSet('EnableWeaponLight', 'DbgEnableWeaponLightOnPlayer')]
    [string]$LightMethod = 'EnableWeaponLight',
    [string]$KeyboardSignalPath,
    [string]$KeyboardDiagnosticPath,
    [ValidateSet('AWARENESS')][string]$NativeKeyboardAction,
    [switch]$TagPlayerForWeaponLight,
    [switch]$RecoverAfterRespawn,
    [string]$RespawnLogPath,
    [switch]$StartOnGameRun
)

$ErrorActionPreference = 'Stop'
if ($RecoverAfterRespawn -and !$NativeKeyboardAction) {
    throw 'Respawn recovery requires native keyboard input.'
}
if ($RespawnLogPath -and !$RecoverAfterRespawn) {
    throw 'A respawn log requires respawn recovery.'
}
if ($StartOnGameRun -and !$RecoverAfterRespawn) {
    throw 'The gameplay lifecycle build requires respawn recovery.'
}
if ($KeyboardDiagnosticPath -and !$KeyboardSignalPath) {
    throw 'Keyboard diagnostics require a keyboard signal path.'
}
if ($NativeKeyboardAction -and ($KeyboardSignalPath -or !$TagPlayerForWeaponLight)) {
    throw 'Native keyboard input requires the player attachment and must be the only input source.'
}
if ($TagPlayerForWeaponLight -and !$KeyboardSignalPath -and !$NativeKeyboardAction) {
    throw 'The player attachment prototype requires a keyboard signal path.'
}
$bundle = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $BundlePath).Path)
$hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bundle))
if ($hash -ne '864B15CDA0E0F854AE31A5CE1019C11EADA9854BD3CEB98D9934747A9668D207') {
    throw 'This experimental builder requires the original script bundle used for analysis.'
}
$path = '/scripts/common/base/threads.lua'
$entry = & (Join-Path $PSScriptRoot 'Read-MafiaLuaBundleEntry.ps1') -BundlePath $BundlePath -ScriptPath $path
$tree = @(& (Join-Path $PSScriptRoot 'Read-MafiaHksPrototype.ps1') -BundlePath $BundlePath -ScriptPath $path -Tree)
$startup, $shutdown, $wait, $event, $eventChild, $next = foreach ($id in '0.0', '0.1', '0.2', '0.3', '0.3.0', '0.4') {
    $tree | Where-Object Index -CEQ $id
}
$extraPrototypes = @()
if ($RespawnLogPath) {
    $extraPrototypes = @($tree | Where-Object Index -cin @('0.4', '0.5', '0.6', '0.6.0'))
    $next = $tree | Where-Object Index -CEQ '0.7'
}

function New-Instruction([int]$Op, [int]$A, [int]$B, [int]$C) {
    [uint32](([long]$Op -shl 25) -bor ($B -shl 17) -bor ($C -shl 8) -bor $A)
}

# The worker starts after threads.lua exports the game's coroutine functions.
# The native worker uses R0 for the registered player, R1 for the listener ID,
# and R2 for a pending refresh after death or a gap with no active player.
# The other workers use R1 for light state and R2 for the input edge.
$code = [Collections.Generic.List[uint32]]::new()
$labels = @{}
$jumps = @{}
function Emit([int]$Op, [int]$A = 0, [int]$B = 0, [int]$C = 0) {
    $code.Add((New-Instruction $Op $A $B $C))
}
function Jump([string]$Label) {
    $jumps[$code.Count] = $Label
    Emit 28
}
function Emit-Diagnostic([string]$Label, [int]$MessageConstant) {
    Emit 91 4 0 8       # GETGLOBAL_MEM io
    Emit 76 20 0 9
    Emit 73 4 4 11      # GETFIELD_R1 io.open
    Emit 76
    Emit 76
    Emit 25 5 0 16      # Diagnostic file path
    Emit 25 6 0 17      # Append mode
    Emit 2 4 3 2
    Emit 1 4 0 0
    Jump $Label
    Emit 8 5 4 274      # SELF file:write
    Emit 25 7 0 $MessageConstant
    Emit 2 5 3 1
    Emit 8 5 4 270      # SELF file:close
    Emit 2 5 2 1
    $labels[$Label] = $code.Count
}

function Emit-RespawnLog([int]$MessageConstant) {
    if (!$RespawnLogPath) { return }
    Emit 66 4 0 1
    Emit 25 5 0 $MessageConstant
    Emit 2 4 2 1
}

Emit 26 0 0              # LOADNIL R0
Emit 13 1 0              # LOADBOOL R1 false
Emit 13 2 0              # LOADBOOL R2 false
if ($RespawnLogPath) {
    Emit-RespawnLog 31
}
$labels.loop = $code.Count
Emit 91 4 0 0            # GETGLOBAL_MEM Sleep
Emit 76 20 0 1
Emit 25 5 0 3            # LOADK 50
Emit 2 4 2 1             # Sleep(50)
Emit 91 3 0 4            # GETGLOBAL_MEM game
Emit 76 20 0 5
Emit 73 3 3 4            # GETFIELD_R1 game.game, as in the shipped player handlers
Emit 76
Emit 76
Emit 8 3 3 263           # SELF game.game:GetActivePlayer
Emit 2 3 2 2
if ($RecoverAfterRespawn) {
    Emit 1 3 0 0         # No active player
    Jump awaitRespawn
    Emit 8 4 3 282       # player:IsDeath()
    Emit 2 4 2 2
    Emit 1 4 0 1
    Jump awaitRespawn
    Emit 1 2 0 1         # Force setup after death, even for the same player
    Jump refreshPlayer
}
Emit 4 1 3 0             # EQ current and previous player
Jump samePlayer
$labels.refreshPlayer = $code.Count
Emit-RespawnLog 33
if ($NativeKeyboardAction) {
    Emit 1 0 0 0
    Jump replacePlayer
    Emit 1 1 0 0
    Jump replacePlayer
    if ($RecoverAfterRespawn) {
        Emit 91 4 0 27   # IsObjectValid(oldPlayer), as used by the shipped scripts
        Emit 76 20 0 28
        Emit 7 5 0
        Emit 2 4 2 2
        Emit 1 4 0 0
        Jump replacePlayer
    }
    Emit 8 4 0 281       # old player:UnregisterInputControlListener
    Emit 7 6 1
    Emit 2 4 3 1
    $labels.replacePlayer = $code.Count
}
Emit 7 0 3               # MOVE current player into R0
Emit 13 1 0
Emit 13 2 0
if ($TagPlayerForWeaponLight) {
    Emit 1 3 0 0
    Jump samePlayer
    $tagMethod = if ($KeyboardDiagnosticPath) { 21 } else { 16 }
    Emit 8 4 3 (256 + $tagMethod)   # SELF player:AddTag
    Emit 25 6 0 ($tagMethod + 1)    # special_attribute
    Emit 25 7 0 ($tagMethod + 2)    # flashlight_attachment
    Emit 25 8 0 ($tagMethod + 3)    # Duration 0, matching Common:Tags:Add
    Emit 2 4 5 1
}
if ($NativeKeyboardAction) {
    Emit 1 3 0 0
    Jump samePlayer
    Emit-RespawnLog 34
    Emit 8 4 3 276        # player:RegisterInputControlListener
    Emit 25 6 0 21        # "Script"
    Emit 25 7 0 22        # Native action
    Emit 13 8 0           # Respect normal input blocking
    Emit 52 9             # Callback context
    Emit 15 9 23 3        # context.player = player
    Emit 13 10 0
    Emit 15 9 24 10       # context.enabled = false
    if ($RespawnLogPath) {
        Emit 66 10 0 1
        Emit 15 9 30 10  # context.log = logger
    }
    Emit 66 10 0 0        # Callback child
    Emit 2 4 7 2
    Emit 7 1 4           # Save registration ID for player replacement.
    Emit-RespawnLog 35
}
$labels.samePlayer = $code.Count
if ($NativeKeyboardAction) {
    Jump loop
    if ($RecoverAfterRespawn) {
        $labels.awaitRespawn = $code.Count
        if ($RespawnLogPath) {
            Emit 1 2 0 1
            Jump loop
            Emit-RespawnLog 32
        }
        Emit 13 2 1
        Jump loop
    }
    Emit 9 0 1
} else {
Emit 1 3 0 0             # TEST player availability
Jump released
if ($KeyboardSignalPath) {
    Emit 91 4 0 8        # GETGLOBAL_MEM io
    Emit 76 20 0 9
    Emit 1 4 0 0
    Jump released
    Emit 73 4 4 11      # GETFIELD_R1 io.open
    Emit 76
    Emit 76
    Emit 25 5 0 12      # LOADK signal path
    Emit 25 6 0 13      # LOADK "r"
    Emit 2 4 3 2        # file = io.open(path, "r")
    Emit 1 4 0 0
    Jump released
    Emit 8 4 4 270      # SELF file:close
    Emit 2 4 2 1
} else {
    Emit 91 6 0 8        # GETGLOBAL_MEM enums
    Emit 76 20 0 9
    Emit 0 6 6 11        # GETFIELD E_Script_GamepadButtons
    Emit 76
    Emit 76
    Emit 8 4 3 270       # SELF player:IsButtonDown
    Emit 0 6 6 12        # GETFIELD BUTT_Y
    Emit 76
    Emit 76
    Emit 2 4 3 2
    Emit 1 4 0 0
    Jump released
    Emit 91 6 0 8        # Fetch the enum again after the call.
    Emit 76 20 0 9
    Emit 0 6 6 11
    Emit 76
    Emit 76
    Emit 8 4 3 270
    Emit 0 6 6 13        # GETFIELD BUTT_X
    Emit 76
    Emit 76
    Emit 2 4 3 2
    Emit 1 4 0 0
    Jump released
}
Emit 1 2 0 1             # While held, skip the toggle.
Jump loop
if ($KeyboardDiagnosticPath -and !$TagPlayerForWeaponLight) { Emit-Diagnostic 'requestLogged' 19 }
Emit 54 1 1              # NOT requested light state
Emit 8 4 3 271           # SELF player:<light method>
Emit 7 6 1
Emit 2 4 3 1
if ($KeyboardDiagnosticPath) { Emit-Diagnostic 'returnLogged' 20 }
Emit 13 2 1
Jump loop
$labels.released = $code.Count
Emit 13 2 0
Jump loop
Emit 9 0 1
}
foreach ($index in $jumps.Keys) {
    $encoded = 65535 + $labels[$jumps[$index]] - $index - 1
    $code[$index] = New-Instruction 28 0 ($encoded -shr 9) ($encoded -band 511)
}

function Write-PrototypeHeader($Writer, [int]$Registers, [int]$Parameters, [int]$Instructions) {
    $Writer.Write([uint32]0)
    $Writer.Write([uint32]$Parameters)
    $Writer.Write([byte]0)
    $Writer.Write([uint32]$Registers)
    $Writer.Write([uint64]$Instructions)
    while ($Writer.BaseStream.Position % 4) { $Writer.Write([byte]0x5F) }
}

function Write-OriginalPrototype($Writer, $Prototype, [uint32[]]$BeforeReturn, [int]$Children, [switch]$TrimDebug, [switch]$AddGameRun) {
    $instructions = $Prototype.Instructions.Count
    $Writer.Write($bundle, $Prototype.HeaderOffset, 13)
    $Writer.Write([uint64]($instructions + $BeforeReturn.Count))
    while ($Writer.BaseStream.Position % 4) { $Writer.Write([byte]0x5F) }
    $last = $Prototype.ConstantOffset - 4
    if ($BeforeReturn.Count -and [BitConverter]::ToUInt32($bundle, $last) -ne (New-Instruction 9 0 1 0)) {
        throw 'Unexpected final startup instruction.'
    }
    if ($AddGameRun) {
        for ($offset = $Prototype.CodeOffset; $offset -lt $last; $offset += 4) {
            $word = [BitConverter]::ToUInt32($bundle, $offset)
            if (($word -shr 25) -eq 66) { $word += [uint32]256 } # root child 0 is the new callback
            $Writer.Write($word)
        }
    } else {
        $Writer.Write($bundle, $Prototype.CodeOffset, $last - $Prototype.CodeOffset)
    }
    foreach ($word in $BeforeReturn) { $Writer.Write($word) }
    $end = if ($TrimDebug) { $Prototype.DebugOffset } else { $Prototype.ChildCountOffset }
    if ($AddGameRun) {
        $count = $Prototype.Constants.Count
        $Writer.Write($bundle, $last, 4)
        $Writer.Write([uint32]($count + 1))
        $Writer.Write($bundle, $last + 8, $end - $last - 8)
        $name = [Text.Encoding]::ASCII.GetBytes('onGameRun')
        $Writer.Write([byte]4)
        $Writer.Write([uint64]($name.Length + 1))
        $Writer.Write($name)
        $Writer.Write([byte]0)
    } else {
        $Writer.Write($bundle, $last, $end - $last)
    }
    if ($TrimDebug) { $Writer.Write([uint32]0) }
    $Writer.Write([uint32]$Children)
}

function Write-Worker($Writer, [int]$Padding) {
    $registers = if ($NativeKeyboardAction) { 11 } elseif ($TagPlayerForWeaponLight) { 9 } elseif ($KeyboardDiagnosticPath) { 8 } else { 7 }
    Write-PrototypeHeader $Writer $registers 0 $code.Count
    foreach ($word in $code) { $Writer.Write($word) }
    $constants = @('Sleep', $null, $null, [single]50, 'game', $null, $null, 'GetActivePlayer')
    if ($NativeKeyboardAction) {
        $constants += @($null, $null, $null, $null, $null, $null, $null, $LightMethod,
            'AddTag', 'special_attribute', 'flashlight_attachment', [single]0,
            'RegisterInputControlListener', 'Script', $NativeKeyboardAction, 'player', 'enabled',
            'UnregisterInputControlListener')
        if ($RecoverAfterRespawn) {
            $constants += @('IsDeath', 'IsObjectValid', $null, $null)
        }
        if ($RespawnLogPath) {
            $constants += @('log', "worker started`n", "waiting for respawn`n", "refreshing player`n",
                "attachment tag applied; registering B`n", "B registration returned`n")
        }
    } elseif ($KeyboardSignalPath) {
        $constants += @('io', $null, $null, 'open', $KeyboardSignalPath, 'r', 'close', $LightMethod)
        if ($KeyboardDiagnosticPath) {
            $constants += @($KeyboardDiagnosticPath, 'a', 'write', "request received`n", "light call returned`n")
        }
        if ($TagPlayerForWeaponLight) {
            $constants += @('AddTag', 'special_attribute', 'flashlight_attachment', [single]0)
        }
    } else {
        $constants += @('enums', $null, $null, 'E_Script_GamepadButtons', 'BUTT_Y', 'BUTT_X',
            'IsButtonDown', $LightMethod)
    }
    $Writer.Write([uint32]($constants.Count + 1))
    foreach ($value in $constants) {
        if ($null -eq $value) { $Writer.Write([byte]0) }
        elseif ($value -is [single]) {
            $Writer.Write([byte]3)
            $Writer.Write($value)
        }
        else {
            $bytes = [Text.Encoding]::UTF8.GetBytes($value)
            $Writer.Write([byte]4)
            $Writer.Write([uint64]($bytes.Length + 1))
            $Writer.Write($bytes)
            $Writer.Write([byte]0)
        }
    }
    # Unused constant fills the original byte range and preserves subsequent alignment.
    $Writer.Write([byte]4)
    $Writer.Write([uint64]($Padding + 1))
    $Writer.Write([Text.Encoding]::ASCII.GetBytes(' ' * $Padding))
    $Writer.Write([byte]0)
    $Writer.Write([uint32]0)
    if ($NativeKeyboardAction) {
        $childCount = if ($RespawnLogPath) { 2 } else { 1 }
        $Writer.Write([uint32]$childCount)
        Write-NativeCallback $Writer
        if ($RespawnLogPath) { Write-RespawnLogger $Writer }
    } else {
        $Writer.Write([uint32]0)
    }
}

function Write-NativeCallback($Writer) {
    $logPress = @()
    $logReturn = @()
    if ($RespawnLogPath) {
        $logPress = @(New-CallbackLog 9)
        $logReturn = @(New-CallbackLog 10)
    }
    $body = @(
        (New-Instruction 0 2 1 0)    # event.m_Activated
        (New-Instruction 76 0 0 0)
        (New-Instruction 76 0 0 0)
        (New-Instruction 1 2 0 0)
        (New-Instruction 28 0 128 (19 + $logPress.Count + $logReturn.Count))
    ) + $logPress + @(
        (New-Instruction 91 2 0 1)   # game.game:GetActivePlayer()
        (New-Instruction 76 20 0 2)
        (New-Instruction 73 2 2 1)
        (New-Instruction 76 0 0 0)
        (New-Instruction 76 0 0 0)
        (New-Instruction 8 2 2 260)
        (New-Instruction 2 2 2 2)
        (New-Instruction 0 3 0 5)    # context.player
        (New-Instruction 76 0 0 0)
        (New-Instruction 76 0 0 0)
        (New-Instruction 4 0 2 3)
        (New-Instruction 28 0 128 (7 + $logReturn.Count))
        (New-Instruction 0 2 0 6)    # context.enabled
        (New-Instruction 76 0 0 0)
        (New-Instruction 76 0 0 0)
        (New-Instruction 54 2 2)
        (New-Instruction 15 0 6 2)
        (New-Instruction 8 4 3 263)
        (New-Instruction 7 6 2)
        (New-Instruction 2 4 3 1)
    ) + $logReturn + @((New-Instruction 9 0 1))
    Write-PrototypeHeader $Writer 7 2 $body.Count
    foreach ($word in $body) { $Writer.Write($word) }
    $values = @('m_Activated', 'game', $null, $null, 'GetActivePlayer', 'player', 'enabled', $LightMethod)
    if ($RespawnLogPath) { $values += @('log', "B callback received`n", "light call returned`n") }
    Write-StringConstants $Writer $values
}

function New-CallbackLog([int]$MessageConstant) {
    New-Instruction 0 4 0 8 # context.log
    New-Instruction 76 0 0 0
    New-Instruction 76 0 0 0
    New-Instruction 25 5 0 $MessageConstant
    New-Instruction 2 4 2 1
}

function Write-RespawnLogger($Writer) {
    # Log calls are infrequent. Open, append a single event, and close each time.
    $body = @(
        (New-Instruction 91 1 0 0) # io
        (New-Instruction 76 20 0 1)
        (New-Instruction 1 1 0 0)
        (New-Instruction 28 0 128 13)
        (New-Instruction 73 1 1 3) # io.open
        (New-Instruction 76 0 0 0)
        (New-Instruction 76 0 0 0)
        (New-Instruction 25 2 0 4)
        (New-Instruction 25 3 0 5)
        (New-Instruction 2 1 3 2)
        (New-Instruction 1 1 0 0)
        (New-Instruction 28 0 128 5)
        (New-Instruction 8 2 1 262) # file:write(message)
        (New-Instruction 7 4 0 0)
        (New-Instruction 2 2 3 1)
        (New-Instruction 8 2 1 263) # file:close()
        (New-Instruction 2 2 2 1)
        (New-Instruction 9 0 1 0)
    )
    Write-PrototypeHeader $Writer 5 1 $body.Count
    foreach ($word in $body) { $Writer.Write($word) }
    Write-StringConstants $Writer @('io', $null, $null, 'open', $RespawnLogPath, 'a', 'write', 'close')
}

function Write-StringConstants($Writer, [object[]]$values) {
    $Writer.Write([uint32]$values.Count)
    foreach ($value in $values) {
        if ($null -eq $value) { $Writer.Write([byte]0); continue }
        $bytes = [Text.Encoding]::UTF8.GetBytes($value)
        $Writer.Write([byte]4)
        $Writer.Write([uint64]($bytes.Length + 1))
        $Writer.Write($bytes)
        $Writer.Write([byte]0)
    }
    $Writer.Write([uint32]0)
    $Writer.Write([uint32]0)
}

$callWorker = @(
    (New-Instruction 0 1 0 5),   # GETFIELD self.StartIndependentThread
    (New-Instruction 76 0 0 0),
    (New-Instruction 76 0 0 0),
    (New-Instruction 66 2 0 0),  # CLOSURE new child
    (New-Instruction 2 1 2 1)
)

function Write-GameRun($Writer, [int]$Padding) {
    $body = @(
        (New-Instruction 91 0 0 0) # StartIndependentThread
        (New-Instruction 76 20 0 1)
        (New-Instruction 66 1 0 0)
        (New-Instruction 2 0 2 1)
        (New-Instruction 9 0 1 0)
    )
    Write-PrototypeHeader $Writer 2 0 $body.Count
    foreach ($word in $body) { $Writer.Write($word) }
    $Writer.Write([uint32]3)
    $Writer.Write([byte]4)
    $name = [Text.Encoding]::ASCII.GetBytes('StartIndependentThread')
    $Writer.Write([uint64]($name.Length + 1))
    $Writer.Write($name)
    $Writer.Write([byte]0)
    $Writer.Write([byte]0)
    $Writer.Write([byte]0)
    $Writer.Write([uint32]0)
    $Writer.Write([uint32]1)
    Write-Worker $Writer $Padding
}

function New-Chunk([int]$Padding, [switch]$Measure) {
    $memory = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($memory)
    try {
        if ($NativeKeyboardAction) {
            $rootPrototype = $tree | Where-Object Index -CEQ '0'
            $writer.Write($bundle, $entry.Offset, $rootPrototype.HeaderOffset - $entry.Offset)
            $children = [BitConverter]::ToUInt32($bundle, $rootPrototype.ChildCountOffset)
            if ($StartOnGameRun) {
                $registerRun = @(
                    (New-Instruction 66 2 0 0),
                    (New-Instruction 27 2 0 $rootPrototype.Constants.Count)
                )
                Write-OriginalPrototype $writer $rootPrototype $registerRun ($children + 1) -TrimDebug -AddGameRun
                Write-GameRun $writer $Padding
            } else {
                Write-OriginalPrototype $writer $rootPrototype @() $children -TrimDebug
            }
        } else {
            $writer.Write($bundle, $entry.Offset, $startup.HeaderOffset - $entry.Offset)
        }
        if ($StartOnGameRun) {
            Write-OriginalPrototype $writer $startup @() 0 -TrimDebug
        } else {
            Write-OriginalPrototype $writer $startup $callWorker 1 -TrimDebug
            Write-Worker $writer $Padding
        }
        Write-OriginalPrototype $writer $shutdown @() 0 -TrimDebug
        Write-OriginalPrototype $writer $wait @() 0 -TrimDebug
        Write-OriginalPrototype $writer $event @() 1 -TrimDebug
        Write-OriginalPrototype $writer $eventChild @() 0 -TrimDebug
        foreach ($prototype in $extraPrototypes) {
            # Keep the final debug record to match the next original header's alignment.
            Write-OriginalPrototype $writer $prototype @() $prototype.ChildCount -TrimDebug:($prototype.Index -cne '0.6.0')
        }
        if ($Measure) { return $memory.Position }
        if ($memory.Position -ne $next.HeaderOffset - $entry.Offset) {
            throw 'Rebuilt startup byte range differs from the original.'
        }
        $writer.Write($bundle, $next.HeaderOffset, $entry.Offset + $entry.Length - $next.HeaderOffset)
        ,$memory.ToArray()
    }
    finally { $writer.Dispose() }
}

$targetSize = $next.HeaderOffset - $entry.Offset
$baseSize = New-Chunk 0 -Measure
if ($baseSize -gt $targetSize) { throw 'The worker exceeds the available startup byte range.' }
$padding = [int]($targetSize - $baseSize)
if ((New-Chunk $padding -Measure) -ne $targetSize) {
    $padding = @(0..7 | ForEach-Object { $padding + $_ - 3 } | Where-Object {
        $_ -ge 0 -and (New-Chunk $_ -Measure) -eq $targetSize
    } | Select-Object -First 1)
    if (!$padding.Count) { throw 'Cannot preserve the original prototype alignment.' }
    $padding = $padding[0]
}
$chunk = New-Chunk $padding
if ($chunk.Length -ne $entry.Length) { throw 'Unexpected replacement chunk length.' }
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputChunk)
$output = [IO.File]::Open($destination, [IO.FileMode]::CreateNew)
try { $output.Write($chunk, 0, $chunk.Length) }
finally { $output.Dispose() }
$inputSource = if ($NativeKeyboardAction) { $NativeKeyboardAction } elseif ($KeyboardSignalPath) { $KeyboardSignalPath } else { 'Controller X + Y' }
[pscustomobject]@{ Chunk = $destination; Script = $path; Length = $chunk.Length; Input = $inputSource; LightMethod = $LightMethod }
