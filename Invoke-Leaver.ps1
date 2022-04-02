<#
.SYNOPSIS
Processes a user as a leaver and converts to a shared mailbox.

.DESCRIPTION
Gets users currently in 'Leavers' OU and processes each one sequentially.
Prompts interactively for:
- Whether a user's manager should be delegated OneDrive, mailbox access.
- What to do with the user's mail, forwarding / Out of office / Deny inbound / nothing.
- Whether to add their manager as an owner on Azure AD / Microsoft 365 groups the user owned.

Disables user, resets password to random, hides from Exchange global address list and sets description (note any existing description will be lost).
Depending on interactive choice: For groups the user was the lone owner of replace them with their manager, or all groups they were an owner of, or none.
Removes a user from all local Active Directory (other than exclusions) and Azure AD / Microsoft 365 groups and ownerships.
Converts the mailbox to a shared mailbox and assigns an Exchange Online (Plan 2) license assigned if needed.
Moves to 'Leavers - Shared Mailboxes' OU.
After all users are processed, runs an Azure AD Connect sync and outputs the summary of users.

Currently relies on group based licensing for removing existing licenses and assigning Exchange Online (Plan 2) if needed.
Currently requires Exchange On-Premises, and assumes that all mailboxes are hosted in Exchange Online.

.PARAMETER LeaverOU
Name or DistinguishedName of the Organizational Unit containing the users this script should process.
Note that you must use DistinguishedName if more than one OU exists in your Active Directory forest with this name.

.PARAMETER LeaverSharedMailboxOU
Name or DistinguishedName of the Organizational Unit that users should be moved to once processed.
Note that you must use DistinguishedName if more than one OU exists in your Active Directory forest with this name.

.PARAMETER GroupExclusionOUs
Name or DistinguishedName of the Organizational Unit(s), where any groups within should be excluded from removal when processing each user.
Note that you must use DistinguishedName if more than one OU exists in your Active Directory forest with this name.
Explanation of default parameter values:
- Group Writeback:
    - If you have the Group Writeback feature of Azure AD Connect enabled, it makes sense to exclude any of those groups from removal when processing as a leaver.
    - This is just to reduce chance of confusion as these groups are a read-only representations of the status in Azure AD / Microsoft 365, local changes are overridden on each Azure AD Connect sync.
- Symbolic Groups:
    - If you have any groups that are used for keeping track of user permissions or accounts for non-SSO platforms, put them in an OU called 'Symbolic Groups'
    - The script will not remove members from these symbolic groups automatically then, as manual action needs performed before removing membership.

.PARAMETER DenyInboundEmailGroup
Name, SamAccountName or DistinguishedName of an Active Directory mail enabled security group or distribution group (synced to Azure AD).
The following Exchange transport rule should be configured (for an example group email alias):
    If the message... Is sent to a member of group 'DenyInboundEmail@domain.example'
    Do the following... reject the message with the explanation 'Account no longer exists'

.PARAMETER SharedMailboxLicenseGroup
Name, SamAccountName or DistinguishedName of an Active Directory security group (synced to Azure AD).
This group should be configured in Azure AD to assign the appropriate Microsoft 365 license, for example Exchange Online (Plan 2).
Any user objects whose mailbox exceeds 50GB or has an Online Archive / In-Place Archive will be added into this group.

.PARAMETER ExchangeServer
On-Premises Microsoft Exchange Server.

.PARAMETER AzureAdSyncServer
The server running Azure AD Connect.

.INPUTS
None. You cannot pipe objects to Invoke-Leaver.ps1.

.OUTPUTS
None.

.EXAMPLE
.\Invoke-Leaver.ps1

Welcome To Microsoft Graph!
Initiating Exchange Online PowerShell session
Initiating Exchange On-Premises PowerShell session to 'exc01'
Initiating SharePoint Online PowerShell session to https://contoso-admin.sharepoint.com
Testing User1: Valid remote user mailbox
Testing User1: Valid Exchange Online license
Testing User1: Mailbox has Online Archive / In-Place Archive
Testing User1: Must remain licensed for Exchange Online after conversion to shared mailbox
Testing User1: Warning, only 1 'Exchange Online (Plan 2)' license free
Testing User1: Has manager 'Example Manager'

Testing User1: OneDrive Ownership
Should manager 'Example Manager' be granted OneDrive permission?
[Y] Yes  [N] No  [T] Terminate  [?] Help (default is "Y"):
...
#>

param (
    [Parameter()][ValidateNotNullOrEmpty()][String]$LeaverOU = 'Leavers',
    [Parameter()][ValidateNotNullOrEmpty()][String]$LeaverSharedMailboxOU = 'Leavers - Shared Mailboxes',
    [Parameter()][ValidateNotNullOrEmpty()][array]$GroupExclusionOUs = ('Group Writeback', 'Symbolic Groups'),
    [Parameter()][ValidateNotNullOrEmpty()][String]$DenyInboundEmailGroup = 'Deny Inbound Email',
    [Parameter()][ValidateNotNullOrEmpty()][String]$SharedMailboxLicenseGroup = 'Exchange Online (Plan 2)',
    [Parameter()][ValidateNotNullOrEmpty()][String]$ExchangeServer = 'exc01',
    [Parameter()][Alias('AADSync')][ValidateNotNullOrEmpty()][String]$AzureAdSyncServer = 'sync01',
    [Parameter()][switch]$SkipLicenseCheck
)

function Start-ExchangeOnlineSession {
    if (Get-PSSession | Where-Object { ($_.State -eq 'Opened') -and $_.ConnectionUri -match 'https://outlook.office365.com/*' }) {
        Write-Host 'An Exchange Online PowerShell session is already active' -ForegroundColor Green
    }
    else {
        Write-Host 'Initiating Exchange Online PowerShell session' -ForegroundColor Yellow
        # https://docs.microsoft.com/en-us/powershell/exchange/connect-to-exchange-online-powershell
        Connect-ExchangeOnline -ShowBanner:$false
    }
}

function Start-ExchangeOnPremisesSession {
    param (
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][String]$Server
    )
    if (Get-PSSession | Where-Object { ($_.State -eq 'Opened') -and $_.ComputerName -match "$Server" }) {
        Write-Host "An Exchange On-Premises PowerShell session to '$Server' is already active" -ForegroundColor Green
    }
    else {
        Write-Host "Initiating Exchange On-Premises PowerShell session to '$Server'" -ForegroundColor Yellow
        # https://docs.microsoft.com/en-us/powershell/exchange/connect-to-exchange-servers-using-remote-powershell?view=exchange-ps
        $global:OnPremisesSession = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri http://$Server/PowerShell/
        # Using a prefix which allows distinguishing between On-Premises and Exchange Online
        Import-PSSession $OnPremisesSession -DisableNameChecking -Prefix OnPremises -AllowClobber | Out-Null
    }
}

function Start-SharePointOnlineSession {
    param (
        [Parameter(Mandatory)][ValidatePattern('^https:\/\/[a-z,A-Z,0-9]*-admin\.sharepoint\.com$')][String]$Url
    )
    try {
        Get-SPOSite -Identity $Url -ErrorAction Stop | Out-Null
        Write-Host "A SharePoint Online PowerShell session is already active to $Url" -ForegroundColor Green
    }
    catch {
        Write-Host "Initiating SharePoint Online PowerShell session to $Url" -ForegroundColor Yellow
        # https://docs.microsoft.com/en-us/powershell/exchange/connect-to-exchange-online-powershell
        Connect-SPOService -Url $Url
    }
}

function Resolve-LicensePlan {
    param (
        [Parameter()][ValidateSet('Mailbox')][string]$Type,
        [Parameter()][System.Object]$AssignedPlans
    )
    # Minimum license service plan a user must have to count as entitled to a mailbox for our purposes
    # Licenses like Microsoft 365 E3, Office 365 E1, Office 365 Business Premium all contain one of these - or bought standalone
    # License reference: https://docs.microsoft.com/en-us/azure/active-directory/enterprise-users/licensing-service-plan-reference
    $minimumMailboxLicenses = @{
        '9aaf7827-d63c-4b61-89c3-182f06f82e5c' = 'Exchange Online (Plan 1)'
        'efb87545-963c-4e0d-99df-69c6916d9eb0' = 'EXCHANGE ONLINE (PLAN 2)'
        '4a82b400-a79f-41a4-b4e2-e94f5787b113' = 'EXCHANGE ONLINE KIOSK'
        '90927877-dcff-4af6-b346-2332c0b15bb7' = 'EXCHANGE ONLINE POP'
        '8c3069c0-ccdb-44be-ab77-986203a67df2' = 'EXCHANGE PLAN 2G'
        'fc52cc4b-ed7d-472d-bbe7-b081c23ecc56' = 'EXCHANGE ONLINE PLAN 1'
        'd42bdbd6-c335-4231-ab3d-c8f348d5aff5' = 'EXCHANGE ONLINE (P1)'
    }
    if ($Type -eq 'Mailbox') {
        if (($AssignedPlans | Where-Object { $_.CapabilityStatus -eq 'Enabled' } | ForEach-Object { $_.servicePlanId -in $minimumMailboxLicenses.Keys }) -contains $true ) {
            # Return true if the servicePlanId of $AssignedPlans was found within the keys of $minimumMailboxLicenses
            $true
        }
        else {
            $false
        }
    }
}

function Get-RandomPassword {
    # Generate a 24 character password, possible characters: a-z, A-Z, 0-9, {]+-[*=@:)}$^%;(_!&#?>/|.
    $charSet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789{]+-[*=@:)}$^%;(_!&amp;#?>/|.'.ToCharArray()
    (1..24 | ForEach-Object { $charSet | Get-Random }) -join ''
}

function Start-AzureAdSync {
    param (
        [Parameter(Mandatory)][Alias('ComputerName')][ValidateNotNullOrEmpty()][String]$Server,
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
}

$standardOptions = @(
    @{ Name = 'Yes'; HelpText = 'Perform this action' } # Default Option
    @{ Name = 'No'; HelpText = 'Skip this action' }
    @{ Name = 'Terminate'; HelpText = 'Stop all actions and end this script' }
)

function Read-UserChoice {
    param (
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Title,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Message,
        [Parameter()][int]$Default = 0,
        [Parameter()][ValidateNotNullOrEmpty()][array]$Options = $standardOptions
    )
    # Build the individual choices and help text from the $Options variable
    $choices = $Options | ForEach-Object {
        New-Object System.Management.Automation.Host.ChoiceDescription "&$($_.Name)", "$($_.HelpText)"
    }
    # Combine the choices into $promptOptions
    $promptOptions = [System.Management.Automation.Host.ChoiceDescription[]]($choices)
    # Invoke our prompt, choice will be stored to $result variable
    $result = $host.UI.PromptForChoice($Title, $Message, $promptOptions, $Default)
    # Output to pipeline the 'Name' of the chosen option - rather than an integer
    $Options.Name[$result]
}

function Set-MailboxOutOfOffice {
    param (
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object]$User,
        [Parameter()][object]$Manager
    )
    try {
        $messageWithManager = "{0} is no longer with {1}, please contact {2} ({3})." -f $User.DisplayName, $User.Company, $Manager.DisplayName, $Manager.EmailAddress
        $messageWithoutManager = "{0} is no longer with {1}." -f $User.DisplayName, $User.Company
        if ($manager) {
            $message = $messageWithManager
        }
        else {
            $message = $messageWithoutManager
        }
        # Build parameters to splat
        $parameters = @{
            Identity         = $User.UserPrincipalName
            AutoReplyState   = 'Enabled'
            ExternalAudience = 'All'
            InternalMessage  = $message
            ExternalMessage  = $message
        }
        Set-MailboxAutoReplyConfiguration @parameters -ErrorAction Stop
        Write-Host ("{0}: Set Out of Office message in Exchange Online" -f $User.DisplayName) -ForegroundColor Green
    }
    catch {
        Write-Error ("{0}: Failed to set Out of Office message in Exchange Online" -f $User.DisplayName)
    }
}

function Set-MailboxForwarding {
    param (
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object]$User,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object]$Manager
    )
    try {
        Set-Mailbox -Identity $User.UserPrincipalName -DeliverToMailboxAndForward $false -ForwardingSMTPAddress $Manager.EmailAddress
        Write-Host ("{0}: Set email forwarding to manager '{1}'" -f $User.DisplayName, $Manager.DisplayName) -ForegroundColor Green
    }
    catch {
        Write-Error ("{0}: Failed to set email forwarding to manager '{1}'" -f $User.DisplayName, $Manager.DisplayName)
    }
}

function Set-MailboxReadAndManage {
    param (
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object]$User,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object]$Manager
    )
    try {
        Add-MailboxPermission -Identity $User.UserPrincipalName -User $Manager.UserPrincipalName -AccessRights FullAccess | Out-Null
        Write-Host ("{0}: Granted Read & Manage permission to '{1}'" -f $User.DisplayName, $Manager.DisplayName) -ForegroundColor Green
    }
    catch {
        Write-Error ("{0}: Failed to grant Read & Manage permission to '{1}'" -f $User.DisplayName, $Manager.DisplayName)
    }
}

function Add-OneDriveSiteAdmin {
    param (
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object]$AzureAdUser,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object]$Manager
    )
    try {
        Set-SPOUser -Site $AzureAdUser.mySite -LoginName $Manager.UserPrincipalName -IsSiteCollectionAdmin $true -ErrorAction Stop | Out-Null
        Write-Host ("{0}: Added OneDrive site collection administrator of '{1}'" -f $AzureAdUser.DisplayName, $Manager.DisplayName) -ForegroundColor Green
        Write-Host ("{0}: OneDrive URL: {1}" -f $AzureAdUser.DisplayName, $AzureAdUser.mySite) -ForegroundColor Cyan
    }
    catch {
        Write-Error $_
        Write-Error ("{0}: Failed to add OneDrive site collection administrator of '{1}'" -f $AzureAdUser.DisplayName, $Manager.DisplayName)
    }
}

function Disable-OneDriveExternalSharing {
    param (
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object]$AzureAdUser
    )
    try {
        # Remove the trailing '/' from the mySite URL, otherwise we get the error 'The managed path ... is not a managed path in this tenant.'
        Set-SPOSite -Identity ($AzureAdUser.mySite -replace '/$', '') -SharingCapability Disabled -ErrorAction Stop | Out-Null
        Write-Host ("{0}: Disabled OneDrive external sharing" -f $AzureAdUser.DisplayName) -ForegroundColor Green
    }
    catch {
        Write-Error $_
        Write-Error ("{0}: Failed to disable OneDrive external sharing" -f $AzureAdUser.DisplayName)
    }
}

function Set-ADGroupMembership {
    param (
        [Parameter(Mandatory)][ValidateSet('Add', 'Remove')][string]$Action,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object]$User,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object]$Groups
    )
    foreach ($group in $Groups) {
        $status = $null
        try {
            switch ($Action) {
                'Add' {
                    $group | Add-ADGroupMember -Members $User
                }
                'Remove' {
                    $group | Remove-ADGroupMember -Members $User -Confirm:$false
                }
            }
            $status = 'Success'
        }
        catch {
            Write-Error ("{0}: Failed to {1} group '{2}'" -f $User.DisplayName, $Action.ToLower(), $group.Name)
            $status = 'Failed'
        }
        # Output a PSCustomObject to the pipeline containing the status of the current group in the loop
        [PSCustomObject] @{
            'Type'         = 'Active Directory'
            'Relationship' = 'Member'
            'Name'         = $group.Name
            'Action'       = $Action
            'Status'       = $status
        }
    }
}

function Add-AzureADManagerOwnership {
    param (
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object]$AzureAdUser,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object]$Manager,
        [Parameter(Mandatory)][object]$Groups
    )
    foreach ($group in $Groups) {
        try {
            $params = @{
                "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($Manager.EmailAddress)"
            }
            New-MgGroupOwnerByRef -GroupId $group.Id -BodyParameter $params -ErrorAction Stop | Out-Null
            Write-Host ("{0}: Added manager '{1}' as an owner of group '{2}' in Azure AD / Microsoft 365" -f $AzureAdUser.DisplayName, $manager.DisplayName, $group.DisplayName) -ForegroundColor Green
        }
        catch {
            Write-Error $_
            Write-Error ("{0}: Failed to add manager '{1}' as an owner of group '{2}' in Azure AD / Microsoft 365" -f $AzureAdUser.DisplayName, $manager.DisplayName, $group.DisplayName)
        }
    }
}

function Remove-AzureADMembership {
    param (
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object]$AzureAdUser,
        [Parameter()][object]$Member,
        [Parameter()][object]$Owner
    )
    foreach ($group in $Member) {
        $status = $null
        try {
            # No PowerShell native Cmdlet, so we use Invoke-MgGraphRequest to call the Graph API directly
            Invoke-MgGraphRequest -Method DELETE -Uri "v1.0/groups/$($group.Id)/members/$($AzureAdUser.Id)/`$ref" | Out-Null
            Write-Host ("{0}: Removed membership from Azure AD / Microsoft 365 group '{1}'" -f $AzureAdUser.DisplayName, $group.DisplayName) -ForegroundColor Green
            $status = 'Success'
        }
        catch {
            Write-Error $_
            Write-Error ("{0}: Failed to remove membership of Azure AD / Microsoft 365 group '{1}'" -f $AzureAdUser.DisplayName, $group.DisplayName)
            $status = 'Failed'
        }
        [PSCustomObject] @{
            'Type'         = 'Azure AD / Microsoft 365'
            'Relationship' = 'Member'
            'Name'         = $group.DisplayName
            'Action'       = 'Remove'
            'Status'       = $status
        }
    }
    foreach ($group in $Owner) {
        $status = $null
        try {
            # No PowerShell native Cmdlet, so we use Invoke-MgGraphRequest to call the Graph API directly
            Invoke-MgGraphRequest -Method DELETE -Uri "v1.0/groups/$($group.Id)/owners/$($AzureAdUser.Id)/`$ref" | Out-Null
            Write-Host ("{0}: Removed ownership from Azure AD / Microsoft 365 group '{1}'" -f $AzureAdUser.DisplayName, $group.DisplayName) -ForegroundColor Green
            $status = 'Success'
        }
        catch {
            Write-Error $_
            Write-Error ("{0}: Failed to remove membership of Azure AD / Microsoft 365 group '{1}'" -f $AzureAdUser.DisplayName, $group.DisplayName)
            $status = 'Failed'
        }
        # Output a PSCustomObject to the pipeline containing the status of the current group in the loop
        [PSCustomObject] @{
            'Type'         = 'Azure AD / Microsoft 365'
            'Relationship' = 'Owner'
            'Name'         = $group.DisplayName
            'Action'       = 'Remove'
            'Status'       = $status
        }
    }
}

function Test-AzureADgroupLoneOwner {
    param (
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object[]]$Groups,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object]$AzureAdUser
    )
    foreach ($group in $Groups) {
        $status = $null
        try {
            $groupOwners = Get-MgGroupOwner -GroupId $Group.Id
            if (($groupOwners.Count -eq 1) -and ($groupOwners.Id -eq $AzureAdUser.Id) ) {
                Write-Host ("{0}: User is the only owner of Azure AD / Microsoft 365 group '{1}'" -f $AzureAdUser.DisplayName, $Group.DisplayName) -ForegroundColor Yellow
                $status = $true
            }
            else {
                $status = $false
            }
        }
        catch {
            Write-Error $_
            Write-Error ("Error getting list of group owners for '{0}'" -f $group.Name)
            $status = 'Error'
        }
        # Output a PSCustomObject to the pipeline containing the owner status of the current group in the loop
        [PSCustomObject] @{
            'Group'     = $Group
            'OnlyOwner' = $status
        }
    }
}

function Get-GroupLicenseStatus {
    param (
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object]$Group
    )
    try {
        # Find the Azure AD group object that comes from the Active Directory group (via Azure AD Connect)
        $azureAdLicenseGroup = Get-MgGroup -Filter "OnPremisesSamAccountName eq '$($Group.SamAccountName)'" -Property DisplayName, AssignedLicenses -ConsistencyLevel eventual -Count groupCount -ErrorAction Stop
        # List all licenses the tenant has
        $tenantSubscribedSkus = Get-MgSubscribedSku
        # Filter the tenant licenses down to only the SkuId that the license group has
        $groupLicense = $tenantSubscribedSkus | Where-Object { $_.SkuId -eq $azureAdLicenseGroup.AssignedLicenses.SkuId } | ForEach-Object {
            # Expand out properties from PrepaidUnits, and add 'UnassignedUnits'
            [PSCustomObject]@{
                Id               = $_.Id
                AppliesTo        = $_.AppliesTo
                CapabilityStatus = $_.CapabilityStatus
                ConsumedUnits    = $_.ConsumedUnits
                EnabledUnits     = $_.PrepaidUnits.Enabled
                SuspendedUnits   = $_.PrepaidUnits.Suspended
                WarningUnits     = $_.PrepaidUnits.Warning
                UnassignedUnits  = ($_.PrepaidUnits.Enabled - $_.ConsumedUnits)
                SkuId            = $_.SkuId
                SkuPartNumber    = $_.SkuPartNumber
                ServicePlans     = $_.ServicePlans
            }
        }
        # Output the groupLicense object to the pipeline
        $groupLicense
    }
    catch {
        Write-Error $_
        Write-Error ("Error getting license status of group '{0}'" -f $group.Name)
    }
}

function Get-StatusObject {
    param (
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object]$User,
        [Parameter(Mandatory)][ValidateSet('Skipped', 'Errored')][string]$Status,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reason
    )
    [PSCustomObject] @{
        'DisplayName'       = $User.DisplayName
        'UserPrincipalName' = $User.UserPrincipalName
        'Status'            = 'Skipped'
        # Take the error message passed in as the 'Reason' parameter and remove the user's DisplayName from the start (if it was present)
        'Reason'            = ($Reason -replace "$($User.DisplayName): ", '')
    }
}

function Get-Object {
    param (
        [Parameter(Mandatory)][ValidateSet('Group', 'OrganizationalUnit')][string]$Type,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][array]$Identity
    )
    $commonParameters = @{
        Properties = 'DistinguishedName', 'Name', 'SamAccountName', 'ObjectSID'
        ErrorAction = 'Stop'
    }
    foreach ($singleIdentity in $Identity) {
        if ($singleIdentity -match $dnRegex) {
            # If the $Identity value is a distinguished name use the Identity parameter to get an exact match
            $parameters = @{
                Identity = "$singleIdentity"
            }
            $results = Get-ADObject @commonParameters @parameters
        }
        else {
            # If the $singleIdentity value was not a distinguished name assume it is a Name or SamAccountName
            # Unfortunately the Identity parameter does not support Name, so we will use the Filter parameter - which might return more than one result
            # Note for groups an edge case is possible where one group has the Name of $Identity, and another group has the SamAccountName of $singleIdentity
            # In that case you would always have too many objects being returned
            $parameters = @{
                Filter = "((Name -eq '$singleIdentity') -or (SamAccountName -eq '$singleIdentity')) -and (ObjectClass -eq '$Type')"
            }
            $results = Get-ADObject @commonParameters @parameters
        }
        
        $resultsCount = ($results | Measure-Object).Count
        switch ($resultsCount) {
            { $_ -eq 0 } {
                Write-Error ("Could not find a {0} with Identity '{1}'" -f $Type, $singleIdentity) -ErrorAction Stop
                break
            }
            { $_ -eq 1 } {
                $results
                break
            }
            { $_ -gt 1 } {
                # If more than one object was returned from our Get-ADGroup command
                Write-Error ("Too many {0} objects returned ({1}) matching Identity '{2}', max 1" -f $Type, $resultsCount, $singleIdentity) -ErrorAction Stop
                break
            }
        }
    }
}

# https://docs.microsoft.com/en-us/powershell/module/microsoft.graph.users
# https://docs.microsoft.com/en-us/powershell/module/microsoft.graph.groups
# https://docs.microsoft.com/en-us/powershell/module/microsoft.graph.identity.directorymanagement
Import-Module -Name Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
# https://docs.microsoft.com/en-us/powershell/module/exchange
Import-Module -Name ExchangeOnlineManagement -ErrorAction Stop
# https://docs.microsoft.com/en-us/powershell/module/sharepoint-online
Import-Module -Name Microsoft.Online.SharePoint.PowerShell -ErrorAction Stop -WarningAction SilentlyContinue
# https://docs.microsoft.com/en-us/powershell/module/activedirectory
Import-Module -Name ActiveDirectory -ErrorAction Stop

# Start the session for Microsoft Graph with the permission scopes we need and send output to console (interactive modern auth prompt)
Write-Host (Connect-MgGraph -Scopes User.ReadWrite.All, Group.ReadWrite.All, Directory.Read.All -ErrorAction Stop)
# Start the session for Exchange Online (interactive modern auth prompt)
Start-ExchangeOnlineSession
# Start the session with Exchange On-Premises (authentication from your PowerShell session with Kerberos or basic auth)
# Note that all cmdlets from Exchange On-Premises will be prefixed with 'OnPremises' to allow easy distinguishing between On-Premises and Exchange Online
Start-ExchangeOnPremisesSession -Server $ExchangeServer

# Get the current tenant's root SharePoint site, then take the WebUrl and add '-admin' after the tenant name
# Note that this does not work with the legacy 'Vanity SharePoint Domain' feature from BPOS-D / Office 365 Dedicated, eg. sharepoint.contoso.com rather than contoso.sharepoint.com
$rootSiteAdminUrl = (Get-MgSite -SiteId root).WebUrl -replace '.sharepoint.com', '-admin.sharepoint.com'
# Connect to SharePoint Online PowerShell (interactive modern auth prompt)
Start-SharePointOnlineSession -Url $rootSiteAdminUrl

# Regex from Daniele Catanesi https://pscustomobject.github.io/powershell/howto/identity%20management/PowerShell-Check-If-String-Is-A-DN/
[regex]$dnRegex = '^(?:(?<cn>CN=(?<name>(?:[^,]|\,)*)),)?(?:(?<path>(?:(?:CN|OU)=(?:[^,]|\,)+,?)+),)?(?<domain>(?:DC=(?:[^,]|\,)+,?)+)$'

try {
    $leaverOuObject = Get-Object -Type OrganizationalUnit -Identity $LeaverOU
    $leaverSharedMailboxOuObject = Get-Object -Type OrganizationalUnit -Identity $LeaverSharedMailboxOU
    $groupExclusionOuObjects = Get-Object -Type OrganizationalUnit -Identity $GroupExclusionOUs
    $denyInboundEmailGroupObject = Get-Object -Type Group -Identity $DenyInboundEmailGroup
    $sharedMailboxLicenseGroupObject = Get-Object -Type Group -Identity $SharedMailboxLicenseGroup
}
catch {
    Write-Error $_ -ErrorAction Stop
}

# Build a regex expression out of the $groupExclusionOuObjects array
# Regex modified from Rob Campbell / Ed Wilson https://devblogs.microsoft.com/scripting/speed-up-array-comparisons-in-powershell-with-a-runtime-regex/
[regex]$groupExclusionOuDnRegex = '(?i)(' + (($groupExclusionOuObjects.DistinguishedName | ForEach-Object { [regex]::escape($_) }) -join '|') + ')$'

# Get all users from the Leavers OU in Active Directory
$users = Get-ADUser -SearchBase $leaverOuObject -Filter * -Properties Company, DisplayName, DistinguishedName, EmailAddress, Manager, MemberOf, SamAccountName, UserPrincipalName
# Get all Azure AD / Microsoft 365 groups that do not come from Active Directory (via Azure AD Connect)
$azureAdGroups = Get-MgGroup -Filter 'onPremisesSyncEnabled ne true' -ConsistencyLevel eventual -Count groupCount

[System.Collections.Generic.List[Object]]$userStatus = @()

:UserForeach foreach ($user in $users) {
    [System.Collections.Generic.List[Object]]$actions = @()
    [System.Collections.Generic.List[Object]]$groupStatus = @()
    
    try {
        switch ($user) {
            { $null -eq $_.EmailAddress } {
                Write-Error ("{0}: EmailAddress is blank" -f $_.DisplayName) -ErrorAction Stop
            }
            { $null -eq $_.Company } {
                Write-Error ("{0}: Company is blank" -f $_.DisplayName) -ErrorAction Stop
            }
        }
    }
    catch {
        # Add the current user to $userStatus with the status of Skipped
        [void]$userStatus.Add(
            $(Get-StatusObject -User $User -Status Skipped -Reason $_)
        )
        # Skip the current user in the foreach loop
        Continue UserForeach
    }
    
    try {
        $azureAdUser = Get-MgUser -UserId $user.UserPrincipalName -Property id, displayName, userPrincipalName, userType, accountEnabled, assignedPlans, mySite
    }
    catch {
        $errorMessage = "{0}: No Azure AD / Microsoft 365 user" -f $user.DisplayName
        Write-Error $errorMessage
        # Add the current user to $userStatus with the status of Skipped
        [void]$userStatus.Add(
            $(Get-StatusObject -User $User -Status Skipped -Reason $errorMessage)
        )
        # Skip the current user in the foreach loop if this 'catch' condition is met
        Continue UserForeach
    }
    
    try {
        $remoteMailbox = Get-OnPremisesRemoteMailbox -Identity $user.UserPrincipalName -ErrorAction Stop
    }
    catch {
        $errorMessage = "{0}: No mailbox known by '{1}'" -f $user.DisplayName, $ExchangeServer
        Write-Error $errorMessage
        # Add the current user to $userStatus with the status of Skipped
        [void]$userStatus.Add(
            $(Get-StatusObject -User $User -Status Skipped -Reason $errorMessage)
        )
        # Skip the current user in the foreach loop if this 'catch' condition is met
        Continue UserForeach
    }
    
    if ($remoteMailbox.RecipientTypeDetails -eq 'RemoteUserMailbox') {
        Write-Host ("{0}: Valid remote user mailbox" -f $user.DisplayName) -ForegroundColor Green
    }
    else {
        $errorMessage = "{0}: No valid remote user mailbox. Expected 'RemoteUserMailbox' got '{1}'" -f $user.DisplayName, $remoteMailbox.RecipientTypeDetails
        Write-Error $errorMessage
        # Add the current user to $userStatus with the status of Skipped
        [void]$userStatus.Add(
            $(Get-StatusObject -User $User -Status Skipped -Reason $errorMessage)
        )
        # Skip the current user in the foreach loop if this 'else' condition is met
        Continue UserForeach
    }
    
    if (Resolve-LicensePlan -Type Mailbox -AssignedPlans $azureAdUser.assignedPlans) {
        Write-Host ("{0}: Valid Exchange Online license" -f $user.DisplayName) -ForegroundColor Green
    }
    else {
        $errorMessage = "{0}: No valid Exchange Online license. License is required at the time of conversion" -f $user.DisplayName
        Write-Error $errorMessage
        # Add the current user to $userStatus with the status of Skipped
        [void]$userStatus.Add(
            $(Get-StatusObject -User $User -Status Skipped -Reason $errorMessage)
        )
        # Skip the current user in the foreach loop if this 'else' condition is met
        Continue UserForeach
    }
    
    try {
        # Get the Exchange Online mailbox object of the current user
        $exoMailbox = Get-EXOMailbox -Identity $user.UserPrincipalName -PropertySets Minimum, Archive -ErrorAction Stop
        # Get the Exchange Online mailbox statistics and take the value sub-property from TotalItemSize
        $exoMailboxSize = ($exoMailbox | Get-EXOMailboxStatistics -ErrorAction Stop).TotalItemSize.Value
    }
    catch {
        Write-Error $_
        # Add the current user to $userStatus with the status of Skipped
        [void]$userStatus.Add(
            $(Get-StatusObject -User $User -Status Skipped -Reason $_)
        )
        # Skip the current user in the foreach loop
        Continue UserForeach
    }
    
    if (($exoMailbox.ArchiveStatus -eq 'Active') -or ($exoMailbox.ArchiveState -eq 'Local') -or ($exoMailboxSize -gt 50GB)) {
        if ($exoMailboxSize -gt 50GB) {
            Write-Host ("{0}: Mailbox larger than 50GB" -f $user.DisplayName) -ForegroundColor Cyan
        }
        if (($exoMailbox.ArchiveStatus -eq 'Active') -or ($exoMailbox.ArchiveState -eq 'Local')) {
            Write-Host ("{0}: Mailbox has Online Archive / In-Place Archive" -f $user.DisplayName) -ForegroundColor Cyan
        }
        Write-Host ("{0}: Must remain licensed for Exchange Online after conversion to shared mailbox" -f $user.DisplayName) -ForegroundColor Yellow
        # Add to $actions
        [void]$actions.Add(
            @{ 'LicenseRequiredAfterConversion' = $true }
        )
        if ($SkipLicenseCheck){
            Write-Host ("{0}: Skipping available license check for '{1}'" -f $user.DisplayName, $sharedMailboxLicenseGroupObject.Name)
        }
        else{
            :LicenseLoop while ($true) {
                $licenseStatus = Get-GroupLicenseStatus -Group $sharedMailboxLicenseGroupObject
                switch ($licenseStatus) {
                    { $_.UnassignedUnits -eq 0 } {
                        $choiceLicenseIssueParams = @{
                            Title   = "{0}: No '{1}' license free" -f $user.DisplayName, $sharedMailboxLicenseGroupObject.Name
                            Message = "User requires a {0} license, but there are no remaining licenses free" -f $sharedMailboxLicenseGroupObject.Name
                            Options = @(
                                @{ Name = 'Retry'; HelpText = 'Check available licenses again, for example after freeing up a license or adding more' } # Default Option
                                @{ Name = 'Skip'; HelpText = 'Skip the current user and do not perform any actions on them' }
                            )
                        }
                        switch (Read-UserChoice @choiceLicenseIssueParams) {
                            'Retry' { break }
                            'Skip' {
                                Write-Host ("{0}: Skipping user without performing changes" -f $user.DisplayName)
                                # Add the current user to $userStatus with the status of Skipped. Add a specific Reason
                                [void]$userStatus.Add(
                                    $(Get-StatusObject -User $User -Status Skipped -Reason ("No remaining {0} licenses free" -f $sharedMailboxLicenseGroupObject.Name))
                                )
                                Continue UserForeach
                            }
                        }
                        break
                    }
                    { $_.UnassignedUnits -eq 1 } {
                        Write-Host ("{0}: Warning, only 1 '{1}' license free" -f $user.DisplayName, $sharedMailboxLicenseGroupObject.Name) -ForegroundColor Yellow
                        Break LicenseLoop
                    }
                    Default { Break LicenseLoop }
                }
            }
        }
    }
    else {
        Write-Host ("{0}: Can be unlicensed after conversion to shared mailbox" -f $user.DisplayName) -ForegroundColor Green
        [void]$actions.Add(
            @{ 'LicenseRequiredAfterConversion' = $false }
        )
    }
    
    if ($user.Manager) {
        # User has a manager defined
        try {
            $manager = Get-AdUser $user.Manager -Properties Enabled, DisplayName, EmailAddress, UserPrincipalName -ErrorAction SilentlyContinue
            switch ($manager) {
                { $_.Enabled -eq $false } {
                    Write-Error ("{0}: Manager '{1}' object is Disabled" -f $user.DisplayName, $_.DisplayName) -ErrorAction Stop
                }
                { $null -eq $_.EmailAddress } {
                    Write-Error ("{0}: Manager '{1}' EmailAddress is blank" -f $user.DisplayName, $_.DisplayName) -ErrorAction Stop
                }
            }
            Write-Host ("{0}: Has manager '{1}'" -f $user.DisplayName, $manager.DisplayName)
        }
        catch {
            Write-Error $_
            # Add the current user to $userStatus with the status of Skipped
            [void]$userStatus.Add(
                $(Get-StatusObject -User $User -Status Skipped -Reason $_)
            )
            # Skip the current user in the foreach loop if this 'catch' condition is met
            Continue UserForeach
        }
    }
    else {
        $manager = $null
        
        $choiceManagerParams = @{
            Title   = "{0}: No manager defined" -f $user.DisplayName
            Message = 'Continue without a manager? No forwarding or delegation of Mailbox, OneDrive etc. can be performed'
        }
        
        switch (Read-UserChoice @choiceManagerParams) {
            'Yes' { break }
            'No' {
                Write-Host ("{0}: Skipping user without performing changes" -f $user.DisplayName)
                # Add the current user to $userStatus with the status of Skipped. Add a specific Reason
                [void]$userStatus.Add(
                    $(Get-StatusObject -User $User -Status Skipped -Reason 'Skipped by user')
                )
                Continue UserForeach
            }
            'Terminate' {
                Break UserForeach
            }
        }
    }
    
    if ($manager -and $azureAdUser.mySite) {
        $choiceOneDriveParams = @{
            Title   = "{0}: OneDrive Ownership" -f $user.DisplayName
            Message = "Should manager '{0}' be granted OneDrive permission?" -f $manager.DisplayName
        }
        
        switch (Read-UserChoice @choiceOneDriveParams) {
            'Yes' {
                [void]$actions.Add(
                    @{ 'OneDriveManagerPermission' = $true }
                )
            }
            'No' { break }
            'Terminate' {
                Break UserForeach
            }
        }
        
        $choiceMailboxPermissionParams = @{
            Title   = "{0}: Mailbox permission" -f $user.DisplayName
            Message = "Should manager '{0}' be granted Read & Manage permission?" -f $manager.DisplayName
        }
        
        switch (Read-UserChoice @choiceMailboxPermissionParams) {
            'Yes' {
                [void]$actions.Add(
                    @{ 'MailboxManagerPermission' = $true }
                )
            }
            'No' { break }
            'Terminate' {
                Break UserForeach
            }
        }
    }
    elseif ($manager -and (-not $azureAdUser.mySite)) {
        Write-Host ("{0}: User has no OneDrive provisioned" -f $user.DisplayName)
    }
    
    $choiceMailHandlingParams = @{
        Title   = "{0}: Mail handling choices" -f $user.DisplayName
        Message = 'Which option should be performed?'
    }
    
    if ($manager) {
        $choiceMailHandlingParams.Options = @(
            @{ Name = 'Forwarding'; HelpText = "Set mailbox forwarding to manager: {0}. Also set Out of Office (for internal MailTip & availability status)" -f $manager.DisplayName }
            @{ Name = 'Out of Office'; HelpText = "Set mailbox Out of Office mentioning manager: {0}" -f $manager.DisplayName }
            @{ Name = 'Deny inbound email'; HelpText = "Reject all inbound (external or internal) emails. Rejection Message: 'Your message couldn't be delivered'. Also set Out of Office (for internal MailTip & availability status)" }
            @{ Name = 'None'; HelpText = "Don't perform any of these actions" }
            @{ Name = 'Skip'; HelpText = 'Skip this user' }
            @{ Name = 'Terminate'; HelpText = 'Stop all actions and end this script' }
        )
    }
    else {
        $choiceMailHandlingParams.Options = @(
            @{ Name = 'Out of Office'; HelpText = 'Set mailbox Out of Office' }
            @{ Name = 'Deny inbound email'; HelpText = "Reject all inbound (external or internal) emails. Rejection Message: 'Your message couldn't be delivered'. Also set Out of Office (for internal MailTip & availability status)" }
            @{ Name = 'None'; HelpText = "Don't perform any of these actions" }
            @{ Name = 'Skip'; HelpText = 'Skip this user' }
            @{ Name = 'Terminate'; HelpText = 'Stop all actions and end this script' }
        )
    }
    
    switch (Read-UserChoice @choiceMailHandlingParams) {
        'Forwarding' {
            [void]$actions.Add(
                @{ 'MailboxManagerForwarding' = $true; 'MailboxOutOfOffice' = $true }
            )
            break
        }
        'Out of Office' {
            [void]$actions.Add(
                @{ 'MailboxOutOfOffice' = $true }
            )
            break
        }
        'Deny inbound email' {
            [void]$actions.Add(
                @{ 'MailboxDenyInbound' = $true; 'MailboxOutOfOffice' = $true }
            )
            break
        }
        'None' { break }
        'Skip' {
            Write-Host ("{0}: Skipping user without performing changes" -f $user.DisplayName)
            # Add the current user to $userStatus with the status of Skipped. Add a specific Reason
            [void]$userStatus.Add(
                $(Get-StatusObject -User $User -Status Skipped -Reason 'Skipped by user')
            )
            Continue UserForeach
        }
        'Terminate' {
            Break UserForeach
        }
    }

    # Get the IDs for all groups that the user is a member of
    ## TODO Confirm if further filtering is needed for members
    $groupMemberships = Get-MgUserMemberOf -UserId $user.UserPrincipalName
    # Take the $azureAdGroups array (all groups) and filter it down to only the groups the user was a member of
    $azureAdGroupMemberships = $azureAdGroups | Where-Object { $_.Id -in $groupMemberships.Id }
    
    # Get the IDs for all Azure AD objects that the user is an owner of (returns more than just groups)
    $groupOwnerships = Get-MgUserOwnedObject -UserId $user.UserPrincipalName
    # Take the $azureAdGroups array (all groups) and filter it down to only the groups the user was an owner of
    $azureAdGroupOwnerships = $azureAdGroups | Where-Object { $_.Id -in $groupOwnerships.Id }
    
    if ($manager) {
        # Only run this section if the user has a manager defined
        $groupOwnerResults = Test-AzureADgroupLoneOwner -Groups $azureAdGroupOwnerships -AzureAdUser $azureAdUser
        $groupLoneOwner = $groupOwnerResults | Where-Object { $_.OnlyOwner -eq $true }
        $groupCoOwner = $groupOwnerResults | Where-Object { $_.OnlyOwner -eq $false }
        
        if ($groupOwnerResults) {
            # Only run this section if the user was an owner of at least one group
            $choiceOnlyGroupOwnerParams = @{
                Title   = "{0}: User is the lone owner of {1} group(s), and a co-owner of {2} groups." -f $user.DisplayName, ($groupLoneOwner | Measure-Object).Count, ($groupCoOwner | Measure-Object).Count
                Message = "Should the user's manager '{0}' replace the user for group ownerships?" -f $manager.DisplayName
            }
            if ($groupLoneOwner -and (-not $groupCoOwner)) {
                # If the user was a lone owner of at least one group, and a co-owner of none
                $choiceOnlyGroupOwnerParams.Options = @(
                    @{ Name = 'Lone ownerships'; HelpText = "For groups the user was the only (lone) owner of, replace them with their manager '{0}'" -f $manager.DisplayName } # Default Option
                    @{ Name = 'None'; HelpText = "Do not add the user's manager '{0}' to any groups the user was an owner of. Note that errors will occur for lone owner groups" -f $manager.DisplayName }
                )
            }
            if ($groupCoOwner -and (-not $groupLoneOwner)) {
                # If the user was a co-owner of at least one group, and a lone owner of none
                $choiceOnlyGroupOwnerParams.Options = @(
                    @{ Name = 'None'; HelpText = "Do not add the user's manager '{0}' to any groups the user was an owner of" -f $manager.DisplayName } # Default Option
                    @{ Name = 'All ownerships'; HelpText = "For groups the user was an owner of, replace them with their manager '{0}'" -f $manager.DisplayName }
                )
            }
            if ($groupLoneOwner -and $groupCoOwner) {
                # If the user was a lone owner of at least one group and a co-owner of at least one group
                $choiceOnlyGroupOwnerParams.Options = @(
                    @{ Name = 'Lone ownerships'; HelpText = "For groups the user was the only (lone) owner of, replace them with their manager '{0}'" -f $manager.DisplayName } # Default Option
                    @{ Name = 'All ownerships'; HelpText = "For groups the user was an owner of, replace them with their manager '{0}'" -f $manager.DisplayName }
                    @{ Name = 'None'; HelpText = "Do not add the user's manager '{0}' to any groups the user was an owner of. Note that errors will occur for lone owner groups" -f $manager.DisplayName }
                )
            }
            
            switch (Read-UserChoice @choiceOnlyGroupOwnerParams) {
                'Lone ownerships' {
                    [void]$actions.Add(
                        @{ 'ReplaceOwnerWithManager' = 'Lone' }
                    )
                    break
                }
                'All ownerships' {
                    [void]$actions.Add(
                        @{ 'ReplaceOwnerWithManager' = 'All' }
                    )
                    break
                }
                'None' { break }
            }
        }
    }
    
    Write-Host "`nWhen conversion is started, $($user.DisplayName) will:"
    Write-Host '- Be disabled if not already'
    Write-Host '- Have password reset to random'
    Write-Host '- Have their description overwritten'
    Write-Host '- Be removed from all Active Directory group memberships'
    Write-Host '- Be removed from all Azure AD / Office 365 group ownerships and memberships'

    if ($azureAdUser.mySite) {
        Write-Host '- Have their OneDrive data deleted automatically in 90 days time'
        Write-Host '- Have external file sharing on their OneDrive disabled'
    }
    switch ($actions) {
        { $_.ReplaceOwnerWithManager -eq 'Lone' } {
            Write-Host ("- Have their manager '{0}' added to {1} groups they were the lone owner of" -f $manager.DisplayName, ($groupLoneOwner | Measure-Object).Count)
        }
        { $_.ReplaceOwnerWithManager -eq 'All' } {
            Write-Host ("- Have their manager '{0}' added to {1} groups they were an owner of" -f $manager.DisplayName, ($groupOwnerResults | Measure-Object).Count)
        }
        { $_.LicenseRequiredAfterConversion } {
            Write-Host ("- Have their Microsoft 365 licenses removed and an {0} license assigned" -f $sharedMailboxLicenseGroupObject.Name)
        }
        { $_.LicenseRequiredAfterConversion -eq $false } {
            Write-Host '- Have their Microsoft 365 licenses removed'
        }
        { $_.MailboxManagerForwarding } {
            Write-Host ("- Have forwarding configured on their mailbox to manager '{0}'" -f $manager.DisplayName)
        }
        { $_.MailboxOutOfOffice } {
            if ($_.MailboxDenyInbound -or $_.MailboxManagerForwarding) {
                $OofMailtipNotice = "`n- Note when forwarding or deny inbound are used, Out of Office is automatically set for MailTip and availability status. No Out of Office email reply will be sent"
            }
            if ($manager) {
                Write-Host ("- Have Out of Office configured on their mailbox mentioning manager '{0}'{1}" -f $manager.DisplayName, $OofMailtipNotice)
            }
            elseif ($null -eq $manager) {
                Write-Host ("- Have Out of Office configured on their mailbox{0}" -f $OofMailtipNotice)
            }
        }
        { $_.MailboxDenyInbound } {
            Write-Host "- Have all inbound emails rejected with error: 'Your message couldn't be delivered'"
        }
        { $_.MailboxManagerPermission } {
            Write-Host ("- Have read and manage permission added on their mailbox for manager '{0}'" -f $manager.DisplayName)
        }
        { $_.OneDriveManagerPermission } {
            Write-Host ("- Have their manager '{0}' added as a OneDrive site collection administrator" -f $manager.DisplayName)
        }
    }
    
    $choiceConversionParams = @{
        Title   = "{0}: Shared mailbox conversion" -f $user.DisplayName
        Message = 'Perform changes and shared mailbox conversion?'
    }
    
    switch (Read-UserChoice @choiceConversionParams) {
        'Yes' { break }
        'No' {
            Write-Host ("{0}: Skipping user without performing changes" -f $user.DisplayName)
            # Add the current user to $userStatus with the status of Skipped. Add a specific Reason
            [void]$userStatus.Add(
                $(Get-StatusObject -User $User -Status Skipped -Reason 'Skipped by user')
            )
            Continue UserForeach
        }
        'Terminate' {
            Break UserForeach
        }
    }
    
    if ($user.Enabled -eq $true) {
        try {
            Disable-ADAccount -Identity $user -ErrorAction Stop
            Write-Host ("{0}: Disabled user" -f $user.DisplayName) -ForegroundColor Cyan
        }
        catch {
            Write-Error $_
            $errorMessage = "{0}: Failed to disable user" -f $user.DisplayName
            Write-Error $errorMessage
            # Add the current user to $userStatus with the status of Errored
            [void]$userStatus.Add(
                $(Get-StatusObject -User $User -Status Errored -Reason $errorMessage)
            )
            # Skip the current user in the foreach loop if this 'catch' condition is met
            Continue UserForeach
        }
    }
    
    try {
        Set-ADAccountPassword -Identity $user -Reset -NewPassword (ConvertTo-SecureString -AsPlainText $(Get-RandomPassword) -Force)
        Write-Host ("{0}: Reset password to random" -f $user.DisplayName) -ForegroundColor Cyan
    }
    catch {
        Write-Error $_
        $errorMessage = "{0}: Failed to reset password to random" -f $user.DisplayName
        Write-Error $errorMessage
        # Add the current user to $userStatus with the status of Errored
        [void]$userStatus.Add(
            $(Get-StatusObject -User $User -Status Errored -Reason $errorMessage)
        )
        # Skip the current user in the foreach loop if this 'catch' condition is met
        Continue UserForeach
    }
    
    try {
        # Tells Exchange On-Premises that the user should be turned into a remote shared mailbox (these values are stored in Active Directory)
        # Note that if a mailbox returns the 'RemoteRecipientType' containing 'ProvisionMailbox' from Get-OnPremisesRemoteMailbox
        # Then the mailbox would be converted into a shared mailbox in Exchange Online on the next Azure AD Connect sync automatically
        # This behaviour doesn't happen for 'Migrated', and for some edge cases
        # To account for this we run both 'Set-OnPremisesRemoteMailbox -Type Shared' and 'Set-Mailbox -Type Shared' to set it on both ends
        Set-OnPremisesRemoteMailbox -Identity $user.UserPrincipalName -Type Shared -ErrorAction Stop
        Write-Host ("{0}: Set remote mailbox type to shared in Exchange On-Premises / Active Directory" -f $user.DisplayName) -ForegroundColor Green
    }
    catch {
        Write-Error $_
        $errorMessage = "{0}: Failed to set remote mailbox type to shared in Exchange On-Premises / Active Directory - skipping all further actions" -f $user.DisplayName
        Write-Error $errorMessage
        # Add the current user to $userStatus with the status of Errored
        [void]$userStatus.Add(
            $(Get-StatusObject -User $User -Status Errored -Reason $errorMessage)
        )
        # Skip the current user in the foreach loop if this 'catch' condition is met
        Continue UserForeach
    }
    
    try {
        # Tells Exchange Online that the user should be turned into a shared mailbox
        # Performing this now also means we can remove the user's license as a part of the main loop
        # Although with group-based licensing sourced from a group in Active Directory, the license will only be removed on the next Azure AD Connect sync
        Set-Mailbox -Identity $user.UserPrincipalName -Type Shared -ErrorAction Stop
        Write-Host ("{0}: Set remote mailbox type to shared in Exchange Online" -f $user.DisplayName) -ForegroundColor Green
    }
    catch {
        Write-Error $_
        $errorMessage = "{0}: Failed to set mailbox type to shared in Exchange Online - skipping all further actions" -f $user.DisplayName
        Write-Error $errorMessage
        # Add the current user to $userStatus with the status of Errored
        [void]$userStatus.Add(
            $(Get-StatusObject -User $User -Status Errored -Reason $errorMessage)
        )
        # Skip the current user in the foreach loop if this 'catch' condition is met
        Continue UserForeach
    }
    
    try {
        Set-ADUser -Identity $user -Replace @{description = "Shared mailbox conversion - $(Get-Date -f yyyy-MM-dd)"; msExchHideFromAddressLists = $true } -ErrorAction Stop
        Write-Host ("{0}: User description set and hidden from GAL" -f $user.DisplayName) -ForegroundColor Cyan
    }
    catch {
        Write-Error $_
        $errorMessage = "{0}: Failed to set user description and/or hide from GAL" -f $user.DisplayName
        Write-Error $errorMessage
        # Add the current user to $userStatus with the status of Errored
        [void]$userStatus.Add(
            $(Get-StatusObject -User $User -Status Errored -Reason $errorMessage)
        )
        # Skip the current user in the foreach loop if this 'catch' condition is met
        Continue UserForeach
    }
    
    try {
        Move-ADObject -Identity $user -TargetPath $leaverSharedMailboxOuObject
        Write-Host ("{0}: User moved to Shared Mailboxes OU" -f $user.DisplayName) -ForegroundColor Cyan
    }
    catch {
        Write-Error $_
        $errorMessage = "{0}: Failed to move user to Shared Mailboxes OU" -f $user.DisplayName
        Write-Error $errorMessage
        # Add the current user to $userStatus with the status of Errored
        [void]$userStatus.Add(
            $(Get-StatusObject -User $User -Status Errored -Reason $errorMessage)
        )
        # Skip the current user in the foreach loop if this 'catch' condition is met
        Continue UserForeach
    }
    
    # If the user has a OneDrive provisioned, then change their OneDrive's sharing policy to only allow internal sharing
    if ($AzureAdUser.mySite) {
        Disable-OneDriveExternalSharing -AzureAdUser $azureAdUser
    }
    
    switch ($actions) {
        { $_.MailboxManagerForwarding } {
            Set-MailboxForwarding -User $user -Manager $manager
            Write-Host ("{0}: Note when forwarding is used, Out of Office is automatically set for MailTip and availability status. No Out of Office email reply will be sent" -f $User.DisplayName) -ForegroundColor Cyan
        }
        { $_.MailboxOutOfOffice } {
            Set-MailboxOutOfOffice -User $user -Manager $manager
        }
        { $_.LicenseRequiredAfterConversion } {
            [void]$groupStatus.Add(
                $(Set-ADGroupMembership -Action Add -User $user -Groups $sharedMailboxLicenseGroupObject)
            )
        }
        { $_.MailboxDenyInbound } {
            [void]$groupStatus.Add(
                $(Set-ADGroupMembership -Action Add -User $user -Groups $denyInboundEmailGroupObject)
            )
            Write-Host ("{0}: Note when Deny Inbound is used, Out of Office is automatically set for MailTip and availability status. No Out of Office email reply will be sent" -f $User.DisplayName) -ForegroundColor Cyan
        }
        { $_.MailboxManagerPermission } {
            Set-MailboxReadAndManage -User $user -Manager $manager
        }
        { $_.OneDriveManagerPermission } {
            Add-OneDriveSiteAdmin -AzureAdUser $azureAdUser -Manager $manager
        }
        { $_.ReplaceOwnerWithManager -eq 'Lone' } {
            Add-AzureADManagerOwnership -AzureAdUser $azureAdUser -Manager $manager -Groups ($groupOwnerResults | Where-Object { $_.OnlyOwner -eq $true }).Group
        }
        { $_.ReplaceOwnerWithManager -eq 'All' } {
            Add-AzureADManagerOwnership -AzureAdUser $azureAdUser -Manager $manager -Groups ($groupOwnerResults).Group
        }
    }
    
    foreach ($adGroupDn in $user.MemberOf) {
        $adGroup = Get-AdGroup -Identity $adGroupDn
        
        if ($adGroupDn -notmatch $groupExclusionOuDnRegex.ToString()) {
            [void]$groupStatus.Add(
                $(Set-ADGroupMembership -Action Remove -User $user -Groups $adGroup)
            )
        }
        else {
            [void]$groupStatus.Add(
                [PSCustomObject] @{
                    'Type'         = 'Active Directory'
                    'Relationship' = 'Member'
                    'Name'         = $adGroup.Name
                    'Action'       = 'Remove'
                    'Status'       = 'Skipped - OU Exclusion'
                }
            )
        }
    }
    
    # Run the Remove-AzureADMembership function passing the needed parameters, take each output PSCustomObject and add individually to $groupStatus
    Remove-AzureADMembership -AzureAdUser $azureAdUser -Member $azureAdGroupMemberships -Owner $azureAdGroupOwnerships | ForEach-Object { [void]$groupStatus.Add($_) }
    
    Write-Host ("{0}: User group summary:" -f $user.DisplayName)
    $groupStatus | Format-Table -AutoSize
    $groupStatus | Export-Csv -NoTypeInformation -Path "$(Get-Date -Format FileDateTimeUniversal)-$($user.DisplayName)-Groups.csv"
    
    Write-Host ("{0}: Finished!" -f $user.DisplayName) -ForegroundColor Yellow
    Write-Host "################################################################################`n" -ForegroundColor Yellow
    
    [void]$userStatus.Add(
        [PSCustomObject] @{
            'DisplayName'       = $user.DisplayName
            'UserPrincipalName' = $user.UserPrincipalName
            'Status'            = 'Completed'
            'LicenseRequired'   = $actions.LicenseRequiredAfterConversion
            'ADGroupsAdded'     = $groupStatus | Where-Object { ($_.Type -eq 'Active Directory') -and ($_.Relationship -eq 'Member') -and ($_.Action -eq 'Add') -and ($_.Status -eq 'Success') } | Measure-Object | Select-Object -ExpandProperty Count
            'ADGroupsRemoved'   = $groupStatus | Where-Object { ($_.Type -eq 'Active Directory') -and ($_.Relationship -eq 'Member') -and ($_.Action -eq 'Remove') -and ($_.Status -eq 'Success') } | Measure-Object | Select-Object -ExpandProperty Count
            'AADMemberRemoved'  = $groupStatus | Where-Object { ($_.Type -eq 'Azure AD / Microsoft 365') -and ($_.Relationship -eq 'Member') -and ($_.Action -eq 'Remove') -and ($_.Status -eq 'Success') } | Measure-Object | Select-Object -ExpandProperty Count
            'AADOwnerRemoved'   = $groupStatus | Where-Object { ($_.Type -eq 'Azure AD / Microsoft 365') -and ($_.Relationship -eq 'Owner') -and ($_.Action -eq 'Remove') -and ($_.Status -eq 'Success') } | Measure-Object | Select-Object -ExpandProperty Count
        }
    )
}

if ($userStatus.Status -contains 'Completed') {
    # After processing users in Leavers OU, if at least one user is completed start an Azure AD Connect sync
    Start-AzureAdSync -Server $AzureAdSyncServer
}

if ($userStatus) {
    Write-Host "`nUser status summary:" -ForegroundColor Yellow
    $userStatus | Format-Table -AutoSize
}

#### Cleanup sessions
# Disconnect-MgGraph
# Disconnect-ExchangeOnline -Confirm:$false
# Remove-PSSession $OnPremisesSession
# Disconnect-SPOService