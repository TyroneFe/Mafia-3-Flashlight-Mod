[CmdletBinding(DefaultParameterSetName = 'Offsets')]
param(
    [Parameter(Mandatory)]
    [string]$BundlePath,

    [Parameter(Mandatory)]
    [string]$ScriptPath,

    [Parameter(Mandatory, ParameterSetName = 'Offsets')]
    [long[]]$BundleOffset,

    [Parameter(Mandatory, ParameterSetName = 'Tree')]
    [switch]$Tree
)

$ErrorActionPreference = 'Stop'
$entry = & (Join-Path $PSScriptRoot 'Read-MafiaLuaBundleEntry.ps1') -BundlePath $BundlePath -ScriptPath $ScriptPath
$file = (Resolve-Path -LiteralPath $BundlePath).Path
$stream = [IO.File]::OpenRead($file)
$reader = [IO.BinaryReader]::new($stream)
try {
    $stream.Position = $entry.Offset
    if ([Convert]::ToHexString($reader.ReadBytes(14)) -ne '1B4C7561510E0104080404000300') {
        throw 'Unsupported Mafia III HKS header.'
    }
    $limit = $entry.Offset + $entry.Length
    $opcodes = @{
        0='GETFIELD'; 2='CALL_I'; 4='EQ'; 7='MOVE'; 8='SELF'; 9='RETURN'
        13='LOADBOOL'; 15='SETFIELD'; 25='LOADK'; 27='SETGLOBAL'; 28='JMP'
        66='CLOSURE'; 69='CALL_I_R1'; 71='TEST_R1'; 73='GETFIELD_R1'
        76='DATA'; 82='CHECKTYPE'; 91='GETGLOBAL_MEM'
    }
    function Skip-ChunkBytes([long]$Count) {
        if ($Count -lt 0 -or $Count -gt $limit - $stream.Position) { throw 'Field exceeds chunk bounds.' }
        $stream.Position += $Count
    }

    function Skip-DebugString {
        $size = $reader.ReadUInt64()
        if ($size -gt $limit - $stream.Position) { throw 'Debug string exceeds chunk bounds.' }
        Skip-ChunkBytes ([long]$size)
    }

    function Read-Prototype([long]$offset, [string]$Index) {
        if ($offset -lt $entry.Offset + 14 -or $offset + 21 -gt $limit) {
            throw "Prototype offset $offset is outside the selected chunk."
        }
        $stream.Position = $offset
        $upvalues = $reader.ReadUInt32()
        $parameters = $reader.ReadUInt32()
        $vararg = $reader.ReadByte()
        $registers = $reader.ReadUInt32()
        $instructionCount = $reader.ReadUInt64()
        if ($registers -gt 255 -or $parameters -gt $registers -or $vararg -gt 7) {
            throw "Invalid prototype header at $offset."
        }
        $padding = (4 - (($stream.Position - $entry.Offset) % 4)) % 4
        $stream.Position += $padding
        $codeOffset = $stream.Position
        if ($stream.Position + 4 -gt $limit -or $instructionCount -gt [Math]::Floor(($limit - $stream.Position - 4) / 4)) {
            throw "Instruction count exceeds the chunk at $offset."
        }
        $instructions = @(for ($i = 0; $i -lt $instructionCount; $i++) {
            $position = $stream.Position
            $word = $reader.ReadUInt32()
            $opcode = [int]($word -shr 25)
            [pscustomobject]@{
                Offset = '0x{0:X}' -f $position
                Opcode = if ($opcodes.ContainsKey($opcode)) { $opcodes[$opcode] } else { "OP_$opcode" }
                A = $word -band 255
                B = ($word -shr 17) -band 255
                C = ($word -shr 8) -band 511
                Bx = ($word -shr 8) -band 131071
            }
        })
        $constantOffset = $stream.Position
        $constantCount = $reader.ReadUInt32()
        if ($constantCount -gt $limit - $stream.Position) { throw "Invalid constant count at $offset." }
        $constants = @(for ($i = 0; $i -lt $constantCount; $i++) {
            if ($stream.Position -ge $limit) { throw "Truncated constant table at $offset." }
            $type = $reader.ReadByte()
            $value = switch ($type) {
                0 { $null }
                1 {
                    if ($stream.Position + 1 -gt $limit) { throw 'Truncated boolean constant.' }
                    [bool]$reader.ReadByte()
                }
                3 {
                    if ($stream.Position + 4 -gt $limit) { throw 'Truncated number constant.' }
                    $reader.ReadSingle()
                }
                4 {
                    if ($stream.Position + 8 -gt $limit) { throw 'Truncated string length.' }
                    $length = $reader.ReadUInt64()
                    if ($length -lt 1 -or $length -gt ($limit - $stream.Position)) {
                        throw "Invalid string constant length at $offset."
                    }
                    $raw = $reader.ReadBytes([int]$length)
                    if ($raw[-1] -ne 0) { throw "String constant lacks a terminator at $offset." }
                    [Text.Encoding]::UTF8.GetString($raw, 0, $raw.Length - 1)
                }
                default { throw "Unsupported constant tag $type at $offset." }
            }
            [pscustomobject]@{ Index = $i; Type = $type; Value = $value }
        })
        $debugOffset = $stream.Position
        $result = [pscustomobject]@{
            Index = $Index
            Offset = '0x{0:X}' -f $offset
            HeaderOffset = $offset
            CodeOffset = $codeOffset
            ConstantOffset = $constantOffset
            DebugOffset = $debugOffset
            Upvalues = $upvalues
            Parameters = $parameters
            Registers = $registers
            Instructions = $instructions
            Constants = $constants
        }
        if (!$Tree) { return $result }

        $debug = $reader.ReadUInt32()
        if ($debug -eq 1) {
            $lineCount = $reader.ReadUInt32()
            $localCount = $reader.ReadUInt32()
            $upvalueNames = $reader.ReadUInt32()
            Skip-ChunkBytes 8
            Skip-DebugString
            Skip-DebugString
            Skip-ChunkBytes (4L * $lineCount)
            for ($j = 0; $j -lt $localCount; $j++) {
                Skip-DebugString
                Skip-ChunkBytes 8
            }
            for ($j = 0; $j -lt $upvalueNames; $j++) { Skip-DebugString }
        }
        elseif ($debug -ne 0) { throw "Unsupported debug record at $offset." }
        $result | Add-Member -NotePropertyName ChildCountOffset -NotePropertyValue $stream.Position
        $children = $reader.ReadUInt32()
        if ($children -gt [Math]::Floor(($limit - $stream.Position) / 21)) {
            throw "Invalid child count at $offset."
        }
        $result | Add-Member -NotePropertyName ChildCount -NotePropertyValue $children
        $result
        for ($j = 0; $j -lt $children; $j++) {
            Read-Prototype $stream.Position "$Index.$j"
        }
    }

    if ($Tree) {
        $types = $reader.ReadUInt32()
        if ($types -ne 13) { throw "Unexpected type table length: $types." }
        for ($i = 0; $i -lt $types; $i++) {
            if ($reader.ReadUInt32() -ne $i) { throw "Unexpected type ID at slot $i." }
            Skip-ChunkBytes $reader.ReadUInt32()
        }
        Read-Prototype $stream.Position '0'
        if ($limit - $stream.Position -ne 12 -or $reader.ReadUInt32() -ne 1 -or $reader.ReadUInt64() -ne 0) {
            throw 'Unsupported structure table after the root prototype.'
        }
    }
    else {
        foreach ($offset in $BundleOffset) { Read-Prototype $offset '' }
    }
}
finally {
    $reader.Dispose()
}
