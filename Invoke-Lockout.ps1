<#
.SYNOPSIS
Locks out a user's Active Directory and Azure AD / Microsoft 365 presence

.DESCRIPTION
Disables a user's Active Directory object, resets password and moves to 'Leavers' OU.
Invokes an Azure AD / Microsoft 365 session sign out.
Runs an Azure AD Connect sync

.PARAMETER Username
Username / SamAccountName of the user(s) to invoke a lockout on.

.PARAMETER LeaverOU
Name or DistinguishedName of the Organisational Unit that a user should be moved to.
Note that you must use DistinguishedName if more than one OU exists in your Active Directory forest with this name.

.PARAMETER AzureAdSyncServer
The server running Azure AD Connect.

.PARAMETER Confirm
If set to $false, no confirmation prompt will appear when a user selection is made interactively or passed via 'Username' property.

.INPUTS
None. You cannot pipe objects to Invoke-Lockout.ps1.

.OUTPUTS
None.

.EXAMPLE
.\Invoke-Lockout.ps1 -Username testing.user1 -LeaverOU Leavers -AzureAdSyncServer sync01

.EXAMPLE
.\Invoke-Lockout.ps1 -Username testing.user1 -LeaverOU 'OU=Leavers,OU=Users,OU=ORG,DC=ad1,DC=example' -AzureAdSyncServer sync01

.EXAMPLE
.\Invoke-Lockout.ps1 -Username testing.user1, testing.user2
#>

param (
    [Parameter(Position = 0, ValueFromPipeline)][Alias("SamAccountName")][ValidateNotNullOrEmpty()][string[]]$Username,
    [Parameter(ValueFromPipeline)][ValidateNotNullOrEmpty()][string]$LeaverOU = 'Leavers',
    [Parameter(ValueFromPipeline)][Alias("AADSync")][ValidateNotNullOrEmpty()][string]$AzureAdSyncServer = 'sync01',
    [Parameter(ValueFromPipeline)][bool]$Confirm = $true
)

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

function Confirm-Lockout {
    param (
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][System.Object]$User
    )
    $params = @{
        Title   = "User {0} ({1}) selected for lockout" -f $User.DisplayName, $User.SamAccountName
        Message = "Perform lockout on {0}?" -f $User.DisplayName
        Options = @(
            @{ Name = 'Yes'; HelpText = 'Perform the lockout: Disable account, reset password to random, revoke Microsoft 365 sessions, move to Leaver OU' } # Default Option
            @{ Name = 'No'; HelpText = 'Skip any action and stop this script' }
        )
    }
    switch (Read-UserChoice @params) {
        'Yes' { $true; break }
        'No' {
            Write-Host ("{0}: Skipping user without performing changes" -f $User.DisplayName) -ForegroundColor Yellow
            $false; break
        }
    }
}

function Get-TargetUserChoice {
    while ($null -eq $targetUser) {
        $search = Read-Host 'Enter the name or username of the user for lockout'
        $result = Get-AdUser -LDAPFilter "(anr=$search)" -Properties DisplayName, SamAccountName
        $resultCount = $result | Measure-Object | Select-Object -ExpandProperty Count
        switch ($resultCount) {
            { $_ -eq 1 } {
                $targetUser = $result
                break
            }
            { $_ -gt 1 } {
                Write-Host "Your search term returned too many results ($resultCount), please be more specific like using full name or Username / SamAccountName"
                break
            }
            Default {
                Write-Host 'No results found with that search term'
            }
        }
    }
    $targetUser.SamAccountName
}

function Get-StatusObject {
    param (
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object]$User,
        [Parameter(Mandatory)][ValidateSet('Completed', 'Skipped', 'Errored')][string]$Status,
        [Parameter()][ValidateNotNullOrEmpty()][string]$Reason
    )
    [PSCustomObject] @{
        'DisplayName'       = $User.DisplayName
        'UserPrincipalName' = $User.UserPrincipalName
        'Status'            = $Status
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
        Properties  = 'DistinguishedName', 'Name', 'SamAccountName', 'ObjectSID'
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

# Regex from Daniele Catanesi https://pscustomobject.github.io/powershell/howto/identity%20management/PowerShell-Check-If-String-Is-A-DN/
[regex]$dnRegex = '^(?:(?<cn>CN=(?<name>(?:[^,]|\,)*)),)?(?:(?<path>(?:(?:CN|OU)=(?:[^,]|\,)+,?)+),)?(?<domain>(?:DC=(?:[^,]|\,)+,?)+)$'

try {
    $leaverOuObject = Get-Object -Type OrganizationalUnit -Identity $LeaverOU
}
catch {
    Write-Error $_ -ErrorAction Stop
}

# https://docs.microsoft.com/en-us/powershell/module/activedirectory
Import-Module -Name ActiveDirectory -ErrorAction Stop
# https://docs.microsoft.com/en-us/powershell/module/microsoft.graph.users.actions
Import-Module -Name Microsoft.Graph.Users.Actions -ErrorAction Stop

# Start the session for Microsoft Graph with the permission scopes we need and null all standard output (interactive modern auth prompt)
Write-Host (Connect-MgGraph -Scopes User.ReadWrite.All -ErrorAction Stop | Out-Null)

if (($null -eq $Username) -or ($Username -eq '')) {
    $Username = Get-TargetUserChoice
}

[System.Collections.Generic.List[Object]]$userStatus = @()

:UserLoop foreach ($individualUsername in $Username) {
    [System.Collections.Generic.List[string]]$errors = @()

    try {
        $user = Get-ADUser -Identity "$individualUsername" -Properties DisplayName, DistinguishedName, Enabled, SamAccountName -ErrorAction Stop
    }
    catch {
        # Add the current user to $userStatus with the status of Skipped
        [void]$userStatus.Add(
            $(Get-StatusObject -User $user -Status Skipped -Reason $_)
        )
        Write-Error $_
        Write-Host ("Skipping '{0}' due to error, does user exist?" -f $individualUsername)
        # Skip the current user in the foreach loop
        Continue UserLoop
    }
    
    if (($Confirm -eq $true) -and ((Confirm-Lockout -User $user) -ne $true)) {
        # Add the current user to $userStatus with the status of Skipped
        [void]$userStatus.Add(
            $(Get-StatusObject -User $user -Status Skipped -Reason 'Skipped by user')
        )
        Continue UserLoop
    }
    
    if ($user.Enabled -eq $true) {
        try {
            Disable-ADAccount -Identity $user -ErrorAction Stop
            Write-Host ("{0}: Disabled user" -f $user.DisplayName) -ForegroundColor Green
        }
        catch {
            [void]$errors.Add("Disable-ADAccount: $_")
            Write-Error $_
            Write-Error ("{0}: Failed to disable user" -f $user.DisplayName)
        }
    }
    elseif ($user.Enabled -eq $false) {
        Write-Host ("{0}: User is already disabled" -f $user.DisplayName) -ForegroundColor Cyan
    }
    
    try {
        Set-ADAccountPassword -Identity $user -Reset -NewPassword (ConvertTo-SecureString -AsPlainText $(Get-RandomPassword) -Force) -ErrorAction Stop
        Write-Host ("{0}: Reset password to random" -f $user.DisplayName) -ForegroundColor Green
    }
    catch {
        [void]$errors.Add("Set-ADAccountPassword: $_")
        Write-Error $_
        Write-Error ("{0}: Failed to reset password to random" -f $user.DisplayName)
    }
    
    # Parse the user's DistinguishedName for the parent OU's DistinguishedName
    $userOu = ($user.DistinguishedName.Substring($($user.DistinguishedName).IndexOf('OU=', [System.StringComparison]::CurrentCultureIgnoreCase)))
    
    if ($userOu -ne $leaverOuObject.DistinguishedName) {
        try {
            Move-ADObject -Identity $user -TargetPath $leaverOuObject.DistinguishedName -ErrorAction Stop
            Write-Host ("{0}: User moved to Leavers OU" -f $user.DisplayName) -ForegroundColor Green
        }
        catch {
            [void]$errors.Add("Move-ADObject: $_")
            Write-Error $_
            Write-Error ("{0}: Failed to move user to Leavers OU" -f $user.DisplayName)
        }
    }
    elseif ($userOu -eq $leaverOuObject.DistinguishedName) {
        Write-Host ("{0}: User is already in Leavers OU" -f $user.DisplayName) -ForegroundColor Cyan
    }
    
    try {
        # Bug with cmdlet in line below, waiting on: https://github.com/microsoftgraph/msgraph-sdk-powershell/issues/834
        # Revoke-MgUserSign -UserId $user.UserPrincipalName -ErrorAction Stop
        Invoke-MgGraphRequest -Uri "v1.0/users/$($user.UserPrincipalName)/microsoft.graph.revokeSignInSessions" -Method POST -ErrorAction Stop | Out-Null
        Write-Host ("{0}: Revoked Microsoft 365 sign in sessions" -f $user.DisplayName) -ForegroundColor Green
    }
    catch {
        [void]$errors.Add("Revoke 365 Sessions: $_")
        Write-Error $_
        Write-Error ("{0}: Failed to revoke Microsoft 365 sign in sessions" -f $user.DisplayName)
    }
    
    if ($errors) {
        # Add the current user to $userStatus with the status of Errored
        [void]$userStatus.Add(
            $(Get-StatusObject -User $user -Status Errored -Reason ($errors -join ', '))
        )
    }
    else {
        # Add the current user to $userStatus with the status of Completed
        [void]$userStatus.Add(
            $(Get-StatusObject -User $user -Status Completed)
        )
    }
}

if ($userStatus.Status -match 'Completed|Errored') {
    Start-AzureAdSync -Server $AzureAdSyncServer
}

if ($userStatus) {
    Write-Host "`nUser status summary:" -ForegroundColor Yellow
    $userStatus | Format-Table -AutoSize
}