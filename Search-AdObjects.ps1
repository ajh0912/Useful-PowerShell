# AH v1.1
# For info on Active Directory's ANR feature see https://social.technet.microsoft.com/wiki/contents/articles/22653.active-directory-ambiguous-name-resolution.aspx
param (
    # Default domains to search are defined here, use the -Domains parameter to override - or change the below line.
    [Parameter(ValueFromPipeline)][string[]]$Domains = ("ad1.example.invalid", "ad2.example.invalid")
)

function Test-ModulePresent {
    param (
        [Parameter(Mandatory,ValueFromPipeline)][string[]]$Name,
        [Parameter(ValueFromPipeline)][boolean]$Import = $false
        )
    if (Get-Module -Name $Name -ListAvailable) {
        Write-Verbose "Module $Name is present"
        if ($Import){
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

function ConvertTo-ParentCanonical {
    param (
    [Parameter(Mandatory,ValueFromPipeline)][string[]]$CanonicalName
    )
    $CanonicalName | ForEach-Object {
        $($_.Substring(0, $($_).lastIndexOf('/')))
    }
}

Test-ModulePresent -Name "ActiveDirectory" -Import $true

Write-Host "Searching domains: $($Domains -join ', ')" -ForegroundColor Cyan

while ($true) {
    $userSearch = Read-Host "Enter a user search term, eg. Username, First Name, Last Name, Department. Press Ctrl+C to cancel"
    $combinedResults = [System.Collections.ArrayList]@()
    
    foreach ($domain in $Domains) {
        $domainObjects = Get-AdUser -Server $domain -LDAPFilter "(|(anr=$userSearch)(department=$userSearch*))" `
        -Properties Enabled, GivenName, Surname, SamAccountName, Department, CanonicalName, EmailAddress, LastLogonDate |
        Select-Object @{ Name = "ParentCanonical"; Expression = { $_.CanonicalName | ConvertTo-ParentCanonical } },
        Enabled, GivenName, Surname, SamAccountName, Department, EmailAddress, LastLogonDate
        
        if ($($domainObjects | Measure-Object).Count -gt 0) {
            Write-Host "Found items matching '$($userSearch)' in $domain" -ForegroundColor Cyan
        }
        else {
            Write-Host "No items matching '$($userSearch)' in $domain" -ForegroundColor Red
        }
        $combinedResults += $domainObjects
    }
    $combinedResults | Format-Table -AutoSize
}