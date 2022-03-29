<#
.SYNOPSIS
v0.6
Queries all Azure AD / Microsoft 365 users and lists any group memberships that should be reviewed.

.DESCRIPTION
For each user in Azure AD / Microsoft 365 (excluding Equipment, Rooms etc), checks if they are disabled or without a mailbox license. If so, lists all their group ownerships and memberships.
Note that this contains all Microsoft 365 groups, Distribution Groups, Security Groups and Mail-enabled Security Groups.
Groups synced from on-premises Active Directory via Azure AD Connect are included.
Note that if a licensed shared mailbox has an enabled user object, it would be missed by this script. Ensure all user objects for shared mailboxes are disabled.

.INPUTS
None. You cannot pipe objects to Get-InvalidMembers.ps1.

.OUTPUTS
System.Object

.EXAMPLE
.\Get-InvalidMembers.ps1

DisplayName       : Example User1
UserPrincipalName : example.user1@ad1.example
Reasons           : User is disabled
GroupOwnerships   : ExampleGroup1
GroupMemberships  : ExampleGroup1

DisplayName       : Example User2
UserPrincipalName : example.user2@ad1.example
Reasons           : User is not licensed for mailbox
GroupOwnerships   : ExampleGroup1, ExampleGroup2
GroupMemberships  : ExampleGroup2

DisplayName       : Example User3
UserPrincipalName : example.user3@ad1.example
Reasons           : User is disabled, User is not licensed for mailbox
GroupOwnerships   : 
GroupMemberships  : ExampleGroup2

.EXAMPLE
.\Get-InvalidMembers.ps1 | Format-Table -AutoSize

DisplayName   UserPrincipalName         Reasons                                            GroupOwnerships              GroupMemberships
-----------   -----------------         -------                                            ---------------              ----------------
Example User1 example.user1@ad1.example User is disabled                                   ExampleGroup1                ExampleGroup1
Example User2 example.user2@ad1.example User is not licensed for mailbox                   ExampleGroup1, ExampleGroup2 ExampleGroup2
Example User3 example.user3@ad1.example User is disabled, User is not licensed for mailbox                              ExampleGroup2

.EXAMPLE
.\Get-InvalidMembers.ps1 | Export-Csv -NoTypeInformation -Encoding UTF8 -Path "$(Get-Date -Format yyyy-MM-dd-HHmm)-InvalidMembers.csv"

# CSV file written to current directory named '2022-01-01-1230-InvalidMembers.csv'
#>


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

# Import all modules, if an error is encountered stop the script executing further
# https://docs.microsoft.com/en-us/powershell/module/exchange/?view=exchange-ps#powershell-v2-module
Import-Module -Name ExchangeOnlineManagement -ErrorAction Stop
# https://docs.microsoft.com/en-us/powershell/module/microsoft.graph.users
Import-Module -Name Microsoft.Graph.Users -ErrorAction Stop
# https://docs.microsoft.com/en-us/powershell/module/microsoft.graph.groups
Import-Module -Name Microsoft.Graph.Groups -ErrorAction Stop

# Start the session for Exchange Online PowerShell V2 module
Start-ExchangeOnlineSession

# Start the session for Microsoft Graph with the permission scopes we need
# Connect-MgGraph by default outputs 'Welcome To Microsoft Graph!' to the pipeline, we want this written to the console only so it's wrapped with Write-Host
# For example we don't want 'Welcome To Microsoft Graph!' ending up in a CSV if we run '.\Get-InvalidMembers.ps1 | Export-Csv'
Write-Host (Connect-MgGraph -Scopes User.Read.All, Group.Read.All -ErrorAction Stop)

# Query all users via Microsoft Graph
$users = Get-MgUser -All -Property id, displayName, userPrincipalName, userType, accountEnabled, assignedPlans
foreach ($user in $users) {
    # Query mailbox via Exchange Online PowerShell V2 module
    $mailbox = Get-EXOMailbox -Identity $user.Id -PropertySets Minimum, Resource -ErrorAction SilentlyContinue
    
    # Only continue if the user is not a Resource mailbox, so we can exclude Equipment, Rooms etc
    if ($mailbox.IsResource -ne $true) {
        [System.Collections.Generic.List[String]]$reason = @()
        
        if ($user.AccountEnabled -eq $false) {
            $reason.Add('User is disabled') | Out-Null
        }
        
        $mailboxPlan = Resolve-LicensePlan -Type Mailbox -AssignedPlans $user.assignedPlans
        # Only add this reason if the user is not entitled to a mailbox, and skip any Guest users
        if (($mailboxPlan -eq $false) -and ($user.userType -eq 'Member')) {
            $reason.Add('User is not licensed for mailbox') | Out-Null
        }
        
        # Only output an object if there was a reason for concern
        if ($reason) {
            # Errors returned from Get-MgGroup are silently ignored, especially for objects piped from Get-MgUserOwnedObject which can contain owned non-group objects
            $groupMemberships = Get-MgUserMemberOf -UserId $user.Id | ForEach-Object { Get-MgGroup -GroupId $_.Id -ErrorAction SilentlyContinue }
            $groupOwnerships = Get-MgUserOwnedObject -UserId $user.Id | ForEach-Object { Get-MgGroup -GroupId $_.Id -ErrorAction SilentlyContinue }
            
            # Only output an object if they were a member or an owner of a group
            if ($groupMemberships -or $groupOwnerships) {
                [PSCustomObject] @{
                    'DisplayName'       = $user.displayName
                    'UserPrincipalName' = $user.userPrincipalName
                    'Reasons'           = $reason -join ', '
                    'GroupOwnerships'   = $groupOwnerships.DisplayName -join ', '
                    'GroupMemberships'  = $groupMemberships.DisplayName -join ', '
                }
            }
        }
    }
}

#### Cleanup sessions
# Disconnect-ExchangeOnline -Confirm
# Disconnect-MgGraph