<#
.SYNOPSIS
v0.1
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

PSComputerName RunspaceId                           Result
-------------- ----------                           ------
sync01         d5531430-15b4-4b08-89e0-091ebff70675 Success

.EXAMPLE
.\Start-AzureAdSync.ps1 -Server sync01 -Credential (Get-Credential)
Supply values for the following parameters:
Credential
# Credential dialog box prompts for Username and Password

PSComputerName RunspaceId                           Result
-------------- ----------                           ------
sync01         d5531430-15b4-4b08-89e0-091ebff70675 Success

.EXAMPLE
.\Start-AzureAdSync.ps1 -Server sync01

System.InvalidOperationException: Connector: example.onmicrosoft.com - AAD is busy.
   at Microsoft.MetadirectoryServices.Scheduler.Scheduler.StartSyncCycle(String overridePolicy, Boolean interactiveMode)
   at SchedulerUtils.StartSyncCycle(SchedulerUtils* , Char* policyType, Int32 interactiveMode, Char** errorString)
    + CategoryInfo          : WriteError: (Microsoft.Ident...ADSyncSyncCycle:StartADSyncSyncCycle) [Start-ADSyncSyncCycle], InvalidOperationException
    + FullyQualifiedErrorId : System.InvalidOperationException: Connector: example.onmicrosoft.com - AAD is busy.
   at Microsoft.MetadirectoryServices.Scheduler.Scheduler.StartSyncCycle(String overridePolicy, Boolean interactiveMode)
   at SchedulerUtils.StartSyncCycle(SchedulerUtils* , Char* policyType, Int32 interactiveMode, Char** errorString),Microsoft.IdentityManagement.PowerShell.Cmdlet.StartADSyncSyncCycle
    + PSComputerName        : sync01

# If an Azure AD sync is already in progress, an error is produced from the Start-ADSyncSyncCycle cmdlet.
#>

param (
    [Parameter()][Alias("ComputerName")][ValidateNotNullOrEmpty()][String]$Server = "sync01.ad1.example",
    [Parameter()][Alias("PolicyType")][ValidateSet("Delta", "Initial")][String]$Type = "Delta",
    [Parameter(ValueFromPipelineByPropertyName)][PSCredential]$Credential
)

$parameters = @{
    ComputerName = $Server
}

if ($Credential){
    # If the 'Credential' parameter is supplied to this script, pass it to Invoke-Command
    $parameters["Credential"]=$Credential
}

Invoke-Command @parameters -ScriptBlock {
    Import-Module ADSync
    Start-ADSyncSyncCycle -PolicyType $Type 
}