<#
.SYNOPSIS
Start an Azure AD Connect sync cycle on the specified server.

.DESCRIPTION
Uses Invoke-Command to run the Start-ADSyncSyncCycle cmdlet remotely on the specified server.
Starts a sync cycle type of 'Delta' or 'Initial' (also known as a full sync). 
If no sync type is specified, defaults to 'Delta'.

Should be invoked from a PowerShell session running as a user who has permission to run an Azure AD Sync on the target server,
or can also be invoked from any user's PowerShell session, as long as a user with permission is supplied via '-Credential (Get-Credential)'.

.PARAMETER Server
The server running Azure AD Connect where the sync command should be performed.

.PARAMETER Type
The type of Azure AD Connect sync to invoke, either 'Delta' or 'Initial' (also known as a full sync).
Defaults to 'Delta' if not specified.

.INPUTS
None. You cannot pipe objects to Start-AzureAdSync.ps1.

.OUTPUTS
System.Object

.EXAMPLE
.\Start-AzureAdSync.ps1 -Server sync01

sync01: Azure AD Connect Delta sync started

.EXAMPLE
.\Start-AzureAdSync.ps1 -Server sync01 -Credential (Get-Credential)
Supply values for the following parameters:
Credential
# Credential dialog box prompts for Username and Password

sync01: Azure AD Connect Delta sync started

.EXAMPLE
.\Start-AzureAdSync.ps1 -Server sync01

sync01: Azure AD Connect sync error 'AAD is busy', a sync is likely already in progress
    + CategoryInfo          : NotSpecified: (:) [Write-Error], WriteErrorException
    + FullyQualifiedErrorId : Microsoft.PowerShell.Commands.WriteErrorException
    + PSComputerName        : sync01

# If an Azure AD sync is already in progress, a more readable error is shown

.EXAMPLE
.\Start-AzureAdSync.ps1 -Server sync01

sync01: Azure AD Connect sync error 'Sync is already running'
    + CategoryInfo          : NotSpecified: (:) [Write-Error], WriteErrorException
    + FullyQualifiedErrorId : Microsoft.PowerShell.Commands.WriteErrorException
    + PSComputerName        : sync01

# If an Azure AD sync is already in progress, a more readable error is shown
#>

param (
    [Parameter()][Alias('ComputerName')][ValidateNotNullOrEmpty()][String]$Server = 'sync01',
    [Parameter()][Alias('PolicyType')][ValidateSet('Delta', 'Initial')][String]$Type = 'Delta',
    [Parameter(ValueFromPipelineByPropertyName)][PSCredential]$Credential
)

$parameters = @{
    ComputerName = $Server
}

if ($Credential) {
    # If the 'Credential' parameter is supplied to this function, include it in the parameters for Invoke-Command
    $parameters['Credential'] = $Credential
}

Invoke-Command @parameters -ScriptBlock {
    Import-Module ADSync
    try {
        Start-ADSyncSyncCycle -PolicyType $Type -ErrorAction Stop | Out-Null
        Write-Host ("{0}: Azure AD Connect {1} sync started" -f $Using:Server, $Using:Type) -ForegroundColor Green
    }
    catch {
        switch ($_) {
            { $_ -match 'Sync is already running' } {
                Write-Error ("{0}: Azure AD Connect sync error 'Sync is already running'" -f $Using:Server)
                break
            }
            { $_ -match 'AAD is busy' } {
                Write-Error ("{0}: Azure AD Connect sync error 'AAD is busy', a sync is likely already in progress" -f $Using:Server)
                break
            }
            Default {
                Write-Error $_
                Write-Error ("{0}: Failed to Azure AD Connect {1} sync" -f $Using:Server, $Using:Type)
            }
        }
    }
}