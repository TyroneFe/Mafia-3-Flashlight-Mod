[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('Install', 'Restore')][string]$Action,
    [Parameter(Mandatory)][string]$ProfilePath
)

$ErrorActionPreference = 'Stop'
if (Get-Process -Name Mafia3DefinitiveEdition -ErrorAction SilentlyContinue) {
    throw 'Exit Mafia III before changing its saved controls.'
}

$profileFile = (Resolve-Path -LiteralPath $ProfilePath).Path
$bytes = [IO.File]::ReadAllBytes($profileFile)
if (!('MafiaInputProfileCrc' -as [type])) {
    Add-Type -TypeDefinition @'
public static class MafiaInputProfileCrc
{
    public static uint Compute(byte[] bytes, int count)
    {
        uint crc = 0xffffffffu;
        for (int index = 0; index < count; index++)
        {
            crc ^= bytes[index];
            for (int bit = 0; bit < 8; bit++)
                crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320u : 0);
        }
        return ~crc;
    }
}
'@
}

$length = $bytes.Length - 4
if ($length -le 0 -or [BitConverter]::ToUInt32($bytes, $length) -ne [MafiaInputProfileCrc]::Compute($bytes, $length)) {
    throw 'The saved controls checksum is invalid.'
}
$encoding = [Text.UTF8Encoding]::new($false, $true)
$content = $encoding.GetString($bytes, 0, $length)
$xml = [Xml.XmlDocument]::new()
$xml.PreserveWhitespace = $true
$xml.LoadXml($content)
$controls = $xml.SelectSingleNode('//S_ControlsSet[m_ControllerDeviceType="2"]')
$element = $controls.SelectSingleNode('./m_ControlGroup/S_ControlGroup[m_Control="AWARENESS"]/m_Primary/S_Control[m_DeviceType="2" and m_ControlMode="32"]/m_ControlElement')
if (!$element) { throw 'The keyboard profile does not contain the expected AWARENESS action.' }

$emptyKey = '4294967295'
$bKey = '48'
$expected, $desired = if ($Action -eq 'Install') { $emptyKey, $bKey } else { $bKey, $emptyKey }
if ($element.InnerText -eq $desired) { Write-Output 'The requested keyboard mapping is already present.'; return }
if ($element.InnerText -ne $expected) { throw 'AWARENESS has a different saved binding.' }
if ($Action -eq 'Install' -and $controls.SelectSingleNode('.//S_Control[m_DeviceType="2" and m_ControlElement="48"]')) {
    throw 'B is already bound in this keyboard profile.'
}
if (!$PSCmdlet.ShouldProcess($profileFile, "$Action the flashlight B mapping")) { return }

$element.InnerText = $desired
$payload = $encoding.GetBytes($xml.OuterXml)
$crc = [BitConverter]::GetBytes([MafiaInputProfileCrc]::Compute($payload, $payload.Length))
$stage = Join-Path ([IO.Path]::GetDirectoryName($profileFile)) ('.flashlight-' + [guid]::NewGuid() + '.tmp')
try {
    [IO.File]::WriteAllBytes($stage, [byte[]]($payload + $crc))
    if (Get-Process -Name Mafia3DefinitiveEdition -ErrorAction SilentlyContinue) {
        throw 'Mafia III started while staging the controls.'
    }
    $originalHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    if ((Get-FileHash -LiteralPath $profileFile).Hash -cne $originalHash) {
        throw 'The saved controls changed while staging the update.'
    }
    [IO.File]::Replace($stage, $profileFile, [NullString]::Value)
}
finally { [IO.File]::Delete($stage) }
Write-Output "$Action completed for the flashlight B mapping."
