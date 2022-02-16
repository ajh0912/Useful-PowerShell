<#
.SYNOPSIS
v0.3
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

function Start-AzureADSession {
    Test-ModulePresent -Name "AzureAD" -Import
    if (([Microsoft.Open.Azure.AD.CommonLibrary.AzureSession]::AccessTokens).Count -gt 0) {
        Write-Host "An Azure AD session is already active" -ForegroundColor Green
    }
    else {
        Write-Host "Initiating Azure AD PowerShell session" -ForegroundColor Yellow
        # https://docs.microsoft.com/en-us/powershell/azure/active-directory/install-adv2
        Connect-AzureAD
    }
}

Start-AzureADSession

function Get-AzureAdGroupInfo {
    $azureAdGroups = Get-AzureADGroup
    foreach ($group in $azureAdGroups) {
        $owners = $group | Get-AzureADGroupOwner
        foreach ($owner in $owners) {
            [System.Collections.ArrayList]$reason = @()
            if ($owner.AccountEnabled -eq $false) {
                $reason.Add("User is disabled") | Out-Null
            }
            # if ($unlicensed) {
            #     $reason.Add("User is unlicensed") | Out-Null
            # }
            if ($reason) {
                [PSCustomObject] @{
                    'GroupName'         = $group.DisplayName
                    'Membership'        = "Owner"
                    'DisplayName'       = $owner.DisplayName
                    'UserPrincipalName' = $owner.UserPrincipalName
                    'Reason'            = $reason -join ", "
                }
            }
        }
        $members = $group | Get-AzureADGroupMember
        foreach ($member in $members) {
            [System.Collections.ArrayList]$reason = @()
            if ($member.AccountEnabled -eq $false) {
                $reason.Add("User is disabled") | Out-Null
            }
            # if ($unlicensed) {
            #     $reason.Add("User is unlicensed") | Out-Null
            # }
            if ($reason) {
                [PSCustomObject] @{
                    'GroupName'         = $group.DisplayName
                    'Membership'        = "Member"
                    'DisplayName'       = $member.DisplayName
                    'UserPrincipalName' = $member.UserPrincipalName
                    'Reason'            = $reason -join ", "
                }
            }
        }
    }
}

Get-AzureAdGroupInfo
# Disconnect-AzureAD