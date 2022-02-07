# AH v0.9
# For info on Active Directory's ANR feature see https://social.technet.microsoft.com/wiki/contents/articles/22653.active-directory-ambiguous-name-resolution.aspx
param (
    # Default domains to search are defined here, use the -Domains parameter to override - or change the below line.
    [Parameter(ValueFromPipeline)][string[]]$Domains = ("ad1.example.invalid", "ad2.example.invalid")
)

Import-Module ActiveDirectory

Write-Host "Searching domains: $($Domains -join ', ')" -ForegroundColor Cyan

while ($true) {
    $userSearch = Read-Host "Enter a user search term, eg. Username, First Name, Last Name, Department. Press Ctrl+C to cancel"
    $combinedResults = [System.Collections.ArrayList]@()
    
    foreach ($domain in $Domains) {
        $results = Get-AdUser -Server $domain -LDAPFilter "(|(anr=$userSearch)(department=$userSearch*))" -Properties Enabled, GivenName, Surname, SamAccountName, Department, CanonicalName, EmailAddress, LastLogonDate |
        Select-Object @{ Name = "ParentCanonical"; Expression = { $($_.CanonicalName.Substring(0, $($_.CanonicalName).lastIndexOf('/'))) } }, Enabled, GivenName, Surname, SamAccountName, Department, EmailAddress, LastLogonDate
        
        if ($($results | Measure-Object).Count -gt 0) {
            Write-Host "Found items matching '$($userSearch)' in $domain" -ForegroundColor Cyan
        }
        else {
            Write-Host "No items matching '$($userSearch)' in $domain" -ForegroundColor Red
        }
        $combinedResults += $results
    }
    $combinedResults | Format-Table -AutoSize
}