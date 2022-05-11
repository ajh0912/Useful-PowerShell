<#
.SYNOPSIS
Performs updates available from Dell Command Update. Drivers, firmware & BIOS/UEFI etc.

.DESCRIPTION
Can be executed from an RMM that sets environment variables to pass information to the script.
The values of the parameters will come from environment variables, unless the parameters are explicitly provided.
Dell Command Update must already be present (installed via .exe, not via Microsoft Store / UWP).

If a BIOS/UEFI password is present on the current computer, then $biosPasswordNeeded should be set to $true,
and the (already encrypted) password should be provided in $biosPwEncrypted.

Note that the computer must be in a trusted environment if a restart is required.
BitLocker will be suspended automatically for the next reboot in order for a seamless end-user experience.
If we did not suspend BitLocker, a BIOS/UEFI update may require the BitLocker recovery key to be entered.

.PARAMETER autoReboot
Dell Command Update will automatically invoke a computer restart if needed when this is set to $true.
Value defaults to an environment variable of the same name, so most RMMs can set the variable.

.PARAMETER biosPasswordNeeded
If the computer has a BIOS/UEFI password, set this to true.
You must provide the (encrypted) BIOS/UEFI password in the 'biosPwEncrypted' parameter.
Value defaults to an environment variable of the same name, so most RMMs can set the variable.

.PARAMETER biosPwEncrypted
This is the (encrypted) BIOS/UEFI password for the computer.
Must be provided if 'biosPasswordNeeded' parameter is true.
For info on how to convert the plaintext password into an encrypted password see:
https://www.dell.com/support/kbdoc/en-uk/000187573/bios-password-is-not-included-in-the-exported-configuration-of-dell-command-update
Value defaults to an environment variable of the same name, so most RMMs can set the variable.

.LINK
https://www.dell.com/support/manuals/en-uk/command-update/dellcommandupdate_rg/dell-command-%7C-update-command-line-interface?guid=guid-c8d5aee8-5523-4d55-a421-1781d3da6f08&lang=en-us
#>
[CmdletBinding(DefaultParameterSetName = 'default')]
param (
    [bool]$autoReboot = $env:autoReboot,
    
    [switch]$biosPasswordNeeded = $env:biosPasswordNeeded,
    
    [ValidateNotNullOrEmpty()]
    [string]$biosPwEncrypted = $env:biosPwEncrypted
)

$dateTime = Get-Date -Format FileDateTimeUniversal
$programFiles = if ([Environment]::Is64BitOperatingSystem) {
    ${env:ProgramFiles(x86)}
}
else {
    $env:ProgramFiles
}
$dcuExePath = Join-Path -Path $programFiles -ChildPath 'Dell\CommandUpdate\dcu-cli.exe'
$standardOutputPath = Join-Path -Path $env:TEMP -ChildPath "$dateTime-DellUpdates-Output.txt"

# Create a list to contain our arguments for Start-Process
[System.Collections.Generic.List[String]]$argumentList = @("/applyUpdates -autoSuspendBitLocker=enable")
switch ($true) {
    # Environment variables are being passed from RMM via either site-wide variables or script variables
    { $autoReboot -eq $true } {
        # Add to the list of Start-Process arguments
        [void]$argumentList.Add("-reboot=enable")
    }
    { $biosPasswordNeeded -eq $true } {
        # See https://www.dell.com/support/kbdoc/en-uk/000187573/bios-password-is-not-included-in-the-exported-configuration-of-dell-command-update
        # Add to the list of Start-Process arguments
        [void]$argumentList.Add("-encryptionkey=`"MyEncryptionKey01`" -encryptedpassword=`"$biosPwEncrypted`"")
    }
}
$dcuParams = @{
    FilePath               = $dcuExePath
    Verbose                = $true
    Wait                   = $true
    # Start-Process cannot redirect standard output to a variable, so it is instead written to a file and read back
    RedirectStandardOutput = $standardOutputPath
    WindowStyle            = 'Hidden'
    ArgumentList           = $argumentList -join ' '
}

try {
    # For debugging you can tail the standard output as it runs with:
    # Get-Content -Tail 100 -Wait $env:TEMP\*DellUpdates-Output*
    Start-Process @dcuParams
    Write-Host 'Updates log:'
    Write-Host (Get-Content -Path $standardOutputPath -Raw)
}
catch {
    # Writing errors to standard error and standard output as some RMM platforms split these into different windows
    Write-Error $_
    Write-Host 'Error: Dell Command Update did not finish successfully, updates log:'
    Write-Host (Get-Content -Path $standardOutputPath -Raw)
    Write-Error "Error: Dell Command Update did not finish successfully" -ErrorAction Stop
}