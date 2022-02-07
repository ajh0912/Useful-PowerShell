# AH v0.8
# For info on Active Directory's ANR feature see https://social.technet.microsoft.com/wiki/contents/articles/22653.active-directory-ambiguous-name-resolution.aspx

$domains = (
    "ad1.example.com",
    "ad2.example.com"
)

Import-Module ActiveDirectory

while ($true) {
    $userSearch = Read-Host "Enter a user search term, eg. Username, First Name, Last Name, Department. Press Ctrl+C to cancel"
    
    $combinedDomainResults = [System.Collections.ArrayList]@()
    
    foreach ($domain in $domains) {
        $originalResults = $null
        $originalResults = Get-AdUser -Server $domain -LDAPFilter "(|(anr=$userSearch)(department=$userSearch*))" -Properties Enabled, GivenName, Surname, SamAccountName, Department, CanonicalName, EmailAddress, LastLogonDate
        $filteredResults = $originalResults | Select-Object @{ Name = "Domain"; Expression = { "$domain" } }, Enabled, GivenName, Surname, SamAccountName, Department, @{ Name = "ParentCanonical"; Expression = { $($_.CanonicalName.Substring(0, $($_.CanonicalName).lastIndexOf('/'))) } }, EmailAddress, LastLogonDate

        if ($($filteredResults | Measure-Object -Property SamAccountName).Count -gt 0) {
            Write-Host "Found items matching '$($userSearch)' in $domain" -ForegroundColor Cyan
        }
        else {
            Write-Host "No items matching '$($userSearch)' in $domain" -ForegroundColor Red
        }
        $combinedDomainResults += $filteredResults
    }

    $combinedDomainResults | Format-Table -AutoSize
}