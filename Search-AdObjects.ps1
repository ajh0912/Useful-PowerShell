# AH v1.2
# For info on Active Directory's ANR feature see https://social.technet.microsoft.com/wiki/contents/articles/22653.active-directory-ambiguous-name-resolution.aspx
param (
    # Default domains to search are defined here, use the -Domains parameter to override - or change the below line.
    [Parameter(ValueFromPipeline)][string[]]$Domains = ("ad1.example.invalid", "ad2.example.invalid"),
    [Parameter(ValueFromPipeline)][string]$UserSearch
)

function Test-ModulePresent {
    param (
        [Parameter(Mandatory, ValueFromPipeline)][string[]]$Name,
        [Parameter(ValueFromPipeline)][boolean]$Import = $false
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

function ConvertTo-ParentCanonical {
    param (
        [Parameter(Mandatory, ValueFromPipeline)][string[]]$CanonicalName
    )
    $CanonicalName | ForEach-Object {
        $($_.Substring(0, $($_).lastIndexOf('/')))
    }
}

function Search-AdObjects {
    param (
        [Parameter(Mandatory, ValueFromPipeline)][string[]]$Domains,
        [Parameter(Mandatory, ValueFromPipeline)][string]$UserSearch
    )
    foreach ($domain in $Domains) {
        $searchParameters = @{
            Server     = $domain
            LDAPFilter = "(|(anr=$UserSearch)(department=$UserSearch*))"
            Properties = "Enabled", "GivenName", "Surname", "SamAccountName", "Department", "CanonicalName", "EmailAddress", "LastLogonDate"
        }
        $domainObjects = Get-AdUser @searchParameters
        
        if ($($domainObjects | Measure-Object).Count -gt 0) {
            Write-Host "Found items matching '$($UserSearch)' in $domain" -ForegroundColor Green

            [PSCustomObject] @{
                Enabled         = $domainObjects.Enabled
                GivenName       = $domainObjects.GivenName
                Surname         = $domainObjects.Surname
                SamAccountName  = $domainObjects.SamAccountName
                Department      = $domainObjects.Department
                ParentCanonical = $domainObjects.CanonicalName | ConvertTo-ParentCanonical
                EmailAddress    = $domainObjects.EmailAddress
                LastLogonDate   = $domainObjects.LastLogonDate
            }
        }
        else {
            Write-Host "No items matching '$($UserSearch)' in $domain" -ForegroundColor Gray
        }
    }
}

Test-ModulePresent -Name "ActiveDirectory" -Import $true

Write-Host "Searching domains: $($Domains -join ', ')" -ForegroundColor Cyan

# If the parameter -UserSearch is populated, just return the search result
if ($UserSearch) {
    Search-AdObjects -Domains $Domains -UserSearch $UserSearch | Format-Table -AutoSize
}
# Else prompt the user to type their search, loop indefinitely unless user breaks loop
else {
    while ($true) {
        $UserSearch = Read-Host "Enter a user search term, eg. Username, First Name, Last Name, Department. Press Ctrl+C to cancel"
        Search-AdObjects -Domains $Domains -UserSearch $UserSearch | Format-Table -AutoSize
    }
}