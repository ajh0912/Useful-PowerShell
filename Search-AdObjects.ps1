<#
.SYNOPSIS

v1.9
Searches for Users or Computers across multiple Active Directory domains/forests.

.DESCRIPTION

For users, matches are returned based on an OR of: Ambiguous Name Resolution, Department, Description
Searching with wildcards can cast a wider net in your search, for example *mysearch* (although a one-ended wildcard can also be used: *mysearch).
An example of this being useful is a search for '*sales*' would also return those with a deparment of 'presales'.
This very wide-net method of matching can also be a detriment, a search for '*ted*' might also return any users with 'converted' or 'created' in their description.

For computers, matches are returned based on an OR of: Ambiguous Name Resolution, Description
See above about wildcards.

Paramters can be optionally specified at execution.
If the 'Search' parameter is not set, the user will be prompted to enter a search term interactively.
After results are returned this way, the user is prompted for another search indefinitely until the script is exited.

.PARAMETER PassThru
Return objects directly from Get-AdUser or Get-AdComputer, rather than formatting to a table.
Can only be used if 'Search' parameter is populated.

.PARAMETER Domains
One or more strings, specifying the domains to search.

.PARAMETER Type
Type of Active Directory object to search for.

.PARAMETER Search
Term to search for in Active Directory, attributes being searched depend on the object type.

.INPUTS

None. You cannot pipe objects to Search-AdObjects.ps1.

.OUTPUTS

Formatted table of the Active Directory object(s) found.
If using 'PassThru' parameter, returns user or computer objects.

.EXAMPLE

PS> .\Search-AdObjects.ps1 -Domains "ad1.example.invalid", "ad2.example.invalid" -Search "bob"
PS> .\Search-AdObjects.ps1 -Type User -Search "bob"
PS> .\Search-AdObjects.ps1 -Search "bob"

ParentCanonical               Enabled GivenName Surname SamAccountName Department EmailAddress              LastLogonDate       Description
---------------               ------- --------- ------- -------------- ---------- ------------              -------------       -----------
ad1.example.invalid/ORG/Users    True Bob       Smith   bob.smith      Sales      bob.smith@example.invalid 01/01/2000 12:00:00 

# Specifying domains manually rather than the default defined within the script.
# Default 'Type' is User, no need to specify that parameter if searching users.

.EXAMPLE

PS> .\Search-AdObjects.ps1 -Search "*sales*"

ParentCanonical               Enabled GivenName Surname SamAccountName Department EmailAddress               LastLogonDate       Description
---------------               ------- --------- ------- -------------- ---------- ------------               -------------       -----------
ad1.example.invalid/ORG/Users    True Bob       Smith   bob.smith      Sales      bob.smith@example.invalid  01/01/2000 12:00:00 
ad1.example.invalid/ORG/Users    True Jane      Baker   jane.baker     Presales   jane.baker@example.invalid 01/01/2000 12:00:00 
ad1.example.invalid/ORG/Users    True John      Green   john.green     Marketing  john.green@example.invalid 01/01/2000 12:00:00 Interim sales

# Using default domains defined within the script.
# Default 'Type' is User, no need to specify that parameter if searching users.

.EXAMPLE

PS> .\Search-AdObjects.ps1 -Domains "ad1.example.invalid", "ad2.example.invalid" -Type Computer -Search "*fileserver*"

ParentCanonical                   Enabled Name Location IPv4Address OperatingSystem              LastLogonDate       Description
---------------                   ------- ---- -------- ----------- ---------------              -------------       -----------
ad1.example.invalid/ORG/Computers    True fs01          10.0.0.10   Windows Server 2019 Standard 01/01/2000 12:00:00 ProjectA Fileserver

# Specifying domains manually rather than the default defined within the script.
# 'Type' needs to be specified as Computer.
# Using wildcards to return

.EXAMPLE

PS> .\Search-AdObjects.ps1 -PassThru -Search "*sales*" | Out-GridView

ParentCanonical                   Enabled Name Location IPv4Address OperatingSystem              LastLogonDate       Description
---------------                   ------- ---- -------- ----------- ---------------              -------------       -----------
ad1.example.invalid/ORG/Computers    True fs01          10.0.0.10   Windows Server 2019 Standard 01/01/2000 12:00:00 ProjectA Fileserver

# Using default domains defined within the script.
# Default 'Type' is User, no need to specify that parameter if searching users.
# Using 'PassThru' to allow passing the user object(s) down the pipeline, in this case to Out-GridView
# 'Search' must be populated if using 'PassThru'
#>

param (
    [Parameter()][switch]$PassThru,
    # Default domains to search are defined here, use the 'Domains' parameter to override - or change the below line
    [Parameter()][string[]]$Domains = ("ad1.example.invalid", "ad2.example.invalid"),
    # Default type of object to search is User, use 'Type' parameter to override
    # TODO add "Group"
    [Parameter()][ValidateSet("User", "Computer")][string]$Type = "User",
    [Parameter()][string]$Search
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
        switch ($Type) {
            "User" {
                $searchParameters = @{
                    Server     = $domain
                    # For info on Active Directory's ANR feature see https://social.technet.microsoft.com/wiki/contents/articles/22653.active-directory-ambiguous-name-resolution.aspx
                    LDAPFilter = "(|(anr=$Search)(department=$Search)(description=$Search))"
                    Properties = "CanonicalName", "Enabled", "GivenName", "Surname", "SamAccountName", "Department", "EmailAddress", "LastLogonDate", "Description"
                }
                $domainObjects = Get-AdUser @searchParameters
            }
            "Computer" {
                $searchParameters = @{
                    Server     = $domain
                    # For info on Active Directory's ANR feature see https://social.technet.microsoft.com/wiki/contents/articles/22653.active-directory-ambiguous-name-resolution.aspx
                    LDAPFilter = "(|(anr=$Search)(description=$Search))"
                    Properties = "CanonicalName", "Enabled", "Name", "Location", "IPv4Address", "OperatingSystem", "LastLogonDate", "Description"
                }
                $domainObjects = Get-AdComputer @searchParameters
            }
            # TODO
            "Group" { 
                Throw 
            }
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

# If the parameter 'Search' is populated, just return the search result
if ($Search) {
    # If 'PassThru' is present, return the results as an object
    if ($PassThru) {
        Search-AdObjects -Domains $Domains -Type $Type -Search $Search
    }
    # If 'PassThru' is absent, return the results as a formatted table
    else {
        Search-AdObjects -Domains $Domains -Type $Type -Search $Search | Format-Table -AutoSize
    }
}
# Else prompt the user to type their search, loop indefinitely unless user breaks loop
else {
    if ($PassThru) {
        Throw "'Search' parameter must be defined if using 'PassThru'"
    }
    while ($true) {
        $Search = Read-Host "Enter a search term, eg. Name, Description, Department. Press Ctrl+C to cancel"
        Search-AdObjects -Domains $Domains -Type $Type -Search $Search | Format-Table -AutoSize
    }
}