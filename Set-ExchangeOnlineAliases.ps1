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
#>

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
        Write-Error "$($item.Identity): Failed to get mailbox"
        Continue ItemLoop
    }
    # Find all current aliases in the EmailAddresses field (lowercase smtp), and remove the 'smtp:'
    $currentAliases = ($mailbox.EmailAddresses -cmatch '^smtp:.*$') -replace 'smtp:', ''
    
    # Find all addresses in the EmailAddresses field that are not 'smtp:'
    $otherAddresses = ($mailbox.EmailAddresses -cmatch '(?<!smtp):.*')
    
    # Convert CSV aliases (comma separated) into an object of smtp: emails
    $futureAliasStrings = ($item.Aliases -split ',' -replace '\s+', '') | ForEach-Object { 'smtp:', $_ -join '' }
    
    $params = @{
        Identity    = $item.Identity
        ErrorAction = 'Stop'
    }
    
    if ($Overwrite) {
        # Check for any aliases not present in the CSV, but currently present in Exchange Online
        $currentAliases | ForEach-Object {
            if ($_ -notin $item.Aliases) {
                Write-Warning ("{0}: Alias {1} not present in CSV, will be removed from EXO" -f $item.Identity, $_)
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
        Write-Error "$($item.Identity): Set-Mailbox failed"
        Write-Error $_.ErrorDetails
        Continue ItemLoop
    }
}