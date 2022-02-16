<#
.SYNOPSIS
v0.4
Query all Azure AD Groups for owners and members that should likely be removed.

.DESCRIPTION
Queries all groups from Azure AD. Note that this contains all Microsoft 365 groups, Distribution Groups, Security Groups and Mail enabled Security Groups.
Groups synced from on-premises Active Directory via Azure AD Connect are included.

.INPUTS
None. You cannot pipe objects to Get-InvalidMembers.ps1.

.OUTPUTS
System.Object

.EXAMPLE
.\Get-InvalidMembers.ps1

GroupName         : ExampleGroup1
Membership        : Member
DisplayName       : Example User1
UserPrincipalName : example.user1@ad1.example
Reason            : User is disabled

GroupName         : ExampleGroup2
Membership        : Owner
DisplayName       : Example User2
UserPrincipalName : example.user2@ad1.example
Reason            : User is disabled

GroupName         : ExampleGroup2
Membership        : Member
DisplayName       : Example User1
UserPrincipalName : example.user1@ad1.example
Reason            : User is disabled

.EXAMPLE
.\Get-InvalidMembers.ps1 | Format-Table -AutoSize

GroupName     Membership DisplayName   UserPrincipalName         Reason
---------     ---------- -----------   -----------------         ------
ExampleGroup1 Member     Example User1 example.user1@ad1.example User is disabled
ExampleGroup2 Owner      Example User2 example.user2@ad1.example User is disabled
ExampleGroup2 Member     Example User1 example.user1@ad1.example User is disabled
#>

function Test-ModulePresent {
    param (
        [Parameter(Mandatory, ValueFromPipeline)][String[]]$Name,
        [Parameter(ValueFromPipeline)][Switch]$Import
    )
    if (Get-Module -Name $Name -ListAvailable) {
        Write-Verbose "Module $Name is present"
        if ($Import) {
            Write-Verbose "Importing module $Name"
            try {
                Import-Module $Name
            }
            catch {
                Throw "Error while importing module $Name"
            }
        }
    }
    else {
        Write-Error "Error, module $Name is not present. If the module is for Windows Server administration, ensure you have RSAT installed https://support.microsoft.com/en-us/topic/e0a3aea3-7bbb-f39c-15db-fd3b51b14cd1"
    }
}

Test-ModulePresent -Name "Microsoft.Graph" -Import
# https://docs.microsoft.com/en-us/graph/powershell/get-started
Connect-MgGraph -Scopes "User.Read.All", "Group.Read.All"

function Get-AzureAdGroupInfo {
    $groups = Get-MgGroup
    foreach ($group in $groups) {
        $owners = Get-MgGroupOwner -GroupId $group.Id -Property Id, displayName, userPrincipalName, accountEnabled
        foreach ($owner in $owners) {
            [System.Collections.ArrayList]$reason = @()
            if ($owner.AdditionalProperties.accountEnabled -eq $false) {
                $reason.Add("User is disabled") | Out-Null
            }
            # if ($unlicensed) {
            #     $reason.Add("User is unlicensed") | Out-Null
            # }
            if ($reason) {
                [PSCustomObject] @{
                    'GroupName'         = $group.DisplayName
                    'Membership'        = "Owner"
                    'DisplayName'       = $owner.AdditionalProperties.displayName
                    'UserPrincipalName' = $owner.AdditionalProperties.userPrincipalName
                    'Reason'            = $reason -join ", "
                }
            }
        }
        $members = Get-MgGroupMember -GroupId $group.Id -Property Id, displayName, userPrincipalName, accountEnabled
        foreach ($member in $members) {
            [System.Collections.ArrayList]$reason = @()
            if ($member.AdditionalProperties.accountEnabled -eq $false) {
                $reason.Add("User is disabled") | Out-Null
            }
            # if ($unlicensed) {
            #     $reason.Add("User is unlicensed") | Out-Null
            # }
            if ($reason) {
                [PSCustomObject] @{
                    'GroupName'         = $group.DisplayName
                    'Membership'        = "Member"
                    'DisplayName'       = $member.AdditionalProperties.displayName
                    'UserPrincipalName' = $member.AdditionalProperties.userPrincipalName
                    'Reason'            = $reason -join ", "
                }
            }
        }
    }
}

Get-AzureAdGroupInfo
# Disconnect-MgGraph