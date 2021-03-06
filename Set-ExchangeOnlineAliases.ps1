<#
.SYNOPSIS
Sets mailbox aliases for Cloud-only users in Exchange Online based on a CSV.

.DESCRIPTION
Imports the identity & aliases combination from a CSV.
Uses Set-Mailbox to apply changes to Exchange Online mailboxes.
Defaults to adding new aliases, but can also overwrite existing aliases.

.PARAMETER CSVFile
Path to the CSV file containing columns 'Identity' and 'Aliases'.
For multiple aliases, comma separate them in the same field/cell.

.PARAMETER Overwrite
If switch is present/true, then any existing 'smtp' (alias) email addresses will be replaced with the CSV contents.
Any other values in the EmailAddresses field are preserved, Eg. SMTP (Primary), SIP, X500.

.EXAMPLE
.\Set-ExchangeOnlineAliases.ps1 -WhatIf

An Exchange Online PowerShell session is already active
What if: Setting mailbox Identity:"Example1@contoso.onmicrosoft.com".
What if: Setting mailbox Identity:"Example2".
What if: Setting mailbox Identity:"acd37fa8-d5d8-49b4-38f4-ba0af2a9139a".

.EXAMPLE
.\Set-ExchangeOnlineAliases.ps1 -CSVFile EXO_Aliases.csv -Overwrite

An Exchange Online PowerShell session is already active
WARNING: The command completed successfully but no settings of 'Example1' have been modified.
WARNING: Example2: Alias Example2@contoso.onmicrosoft.com not present in CSV, will be removed from EXO
WARNING: Example2: Alias Example2@contoso.mail.onmicrosoft.com not present in CSV, will be removed from EXO
WARNING: Example3: Alias Example3@contoso.com not present in CSV, will be removed from EXO
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [ValidateScript({ Test-Path $_ })]
    [string]$CSVFile = 'Aliases.csv',

    [switch]$Overwrite
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

#Requires -Modules ExchangeOnlineManagement
Start-ExchangeOnlineSession

$csvContent = Import-Csv $CSVFile -ErrorAction Stop

:ItemLoop Foreach ($item in $csvContent) {
    try {
        # Get the mailbox for the current row of the CSV
        $mailbox = Get-EXOMailbox -Identity $item.Identity -ErrorAction Stop
    }
    catch {
        Write-Error $_
        Continue ItemLoop
    }
    # Find all current aliases in the EmailAddresses field (lowercase smtp), and remove the 'smtp:'
    $currentAliases = ($mailbox.EmailAddresses -cmatch '^smtp:.*$') -replace 'smtp:', ''
    
    # Find all addresses in the EmailAddresses field that are not 'smtp:'
    $otherAddresses = ($mailbox.EmailAddresses -cmatch '(?<!smtp):.*')
    
    # Split value from Aliases cell into multiple strings and remove whitespace
    $futureAliases = $item.Aliases -split ',' -replace '\s+', ''

    # Convert CSV aliases (comma separated) into an object of smtp: emails
    $futureAliasStrings = $futureAliases | ForEach-Object { 'smtp:', $_ -join '' }
    
    $params = @{
        Identity    = $item.Identity
        ErrorAction = 'Stop'
        WhatIf      = $WhatIfPreference
    }
    
    if ($Overwrite) {
        # Check for any aliases not present in the CSV, but currently present in Exchange Online
        $currentAliases | ForEach-Object {
            if ($_ -notin $futureAliases) {
                Write-Warning ("{0}: Alias {1} not present in CSV, will be removed from EXO" -f $mailbox.Name, $_)
            }
        }
        # Replace current EmailAddress field with all original SMTP (Primary), SIP, X500 etc values, plus new smtp (alias) values
        $params.EmailAddress = $otherAddresses + $futureAliasStrings
    }
    else {
        # Add to existing EmailAddress field
        $params.EmailAddress = @{Add = $futureAliasStrings }
    }

    try {
        Set-Mailbox @params
    }
    catch {
        Write-Error $_
        Continue ItemLoop
    }
}