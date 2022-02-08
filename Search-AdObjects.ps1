# AH v1.5
param (
    # Default domains to search are defined here, use the -Domains parameter to override - or change the below line.
    [Parameter(ValueFromPipeline)][string[]]$Domains = ("ad1.example.invalid", "ad2.example.invalid"),
    # Default type of object to search is User, use -Type parameter to override
    # TODO add "Group"
    [Parameter(ValueFromPipeline)][ValidateSet("User", "Computer")][string]$Type = "User",
    [Parameter(ValueFromPipeline)][string]$Search
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
        # TODO add "Group"
        [Parameter(Mandatory, ValueFromPipeline)][ValidateSet("User", "Computer")][string]$Type,
        [Parameter(Mandatory, ValueFromPipeline)][string]$Search
    )
    foreach ($domain in $Domains) {
        $baseSearchParameters = @{
            Server = $domain
        }
        switch ($Type) {
            "User" {
                $searchParameters = $baseSearchParameters + @{
                    # For info on Active Directory's ANR feature see https://social.technet.microsoft.com/wiki/contents/articles/22653.active-directory-ambiguous-name-resolution.aspx
                    LDAPFilter = "(|(anr=$Search)(department=*$Search*)(description=*$Search*))"
                    Properties = "CanonicalName", "Enabled", "GivenName", "Surname", "SamAccountName", "Department", "EmailAddress", "LastLogonDate", "Description"
                }
                $domainObjects = Get-AdUser @searchParameters
            }
            "Computer" {
                $searchParameters = $baseSearchParameters + @{
                    LDAPFilter = "(|(anr=$Search)(description=*$Search*))"
                    Properties = "CanonicalName", "Enabled", "Name", "Location", "IPv4Address", "OperatingSystem", "LastLogonDate", "Description"
                }
                $domainObjects = Get-AdComputer @searchParameters
            }
            # TODO
            "Group" { Throw }
        }
           
        if ($($domainObjects | Measure-Object).Count -gt 0) {
            Write-Host "Found $($Type)(s) matching '$($Search)' in $domain" -ForegroundColor Green
            
            switch ($Type) {
                "User" {
                    $domainObjects | Select-Object @{ Name = "ParentCanonical"; Expression = { $_.CanonicalName | ConvertTo-ParentCanonical } },
                    Enabled, GivenName, Surname, SamAccountName, Department, EmailAddress, LastLogonDate, Description
                }
                "Computer" {
                    $domainObjects | Select-Object @{ Name = "ParentCanonical"; Expression = { $_.CanonicalName | ConvertTo-ParentCanonical } },
                    Enabled, Name, Location, IPv4Address, OperatingSystem, LastLogonDate, Description
                }
                # TODO
                "Group" {
                    Throw
                }
            }
        }
        else {
            Write-Host "No $($Type)s matching '$($Search)' in $domain" -ForegroundColor Gray
        }
    }
}

Test-ModulePresent -Name "ActiveDirectory" -Import $true

Write-Host "Searching domains: $($Domains -join ', ')" -ForegroundColor Cyan

# If the parameter -Search is populated, just return the search result
if ($Search) {
    Search-AdObjects -Domains $Domains -Type $Type -Search $Search | Format-Table -AutoSize
}
# Else prompt the user to type their search, loop indefinitely unless user breaks loop
else {
    while ($true) {
        $Search = Read-Host "Enter a search term, eg. Name, Description, Department. Press Ctrl+C to cancel"
        Search-AdObjects -Domains $Domains -Type $Type -Search $Search | Format-Table -AutoSize
    }
}