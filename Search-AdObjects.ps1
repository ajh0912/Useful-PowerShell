<#
.SYNOPSIS
Searches for Users or Computers across multiple Active Directory domains/forests.

.DESCRIPTION
For users, matches are returned based on an OR of: Ambiguous Name Resolution, Department, Description
Searching with wildcards can cast a wider net in your search, for example *mysearch* (although a one-ended wildcard can also be used: *mysearch).
An example of this being useful is a search for '*sales*' would also return those with a department of 'Pre-sales'.
This very wide-net method of matching can also be a detriment, a search for '*ted*' might also return any users with 'converted' or 'created' in their description.

For computers, matches are returned based on an OR of: Ambiguous Name Resolution, Description
See above about wildcards.

Parameters can be optionally specified at execution.
If the 'Search' parameter is not set, the user will be prompted to enter a search term interactively.
After results are returned this way, the user is prompted for another search indefinitely until the script is exited.

.PARAMETER PassThru
Return objects directly from Get-AdUser or Get-AdComputer, rather than formatting to a table.
Can only be used if 'Search' parameter is populated.

.PARAMETER Servers
One or more strings, specifying the servers to query.
A specific domain controller can be used, or if the domain FQDN entered then one domain controller in the domain will be queried.

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
.\Search-AdObjects.ps1 -Domains ad1.example, ad2.example -Search bob

ParentCanonical       Enabled GivenName Surname SamAccountName Department EmailAddress          LastLogonDate       Description
---------------       ------- --------- ------- -------------- ---------- ------------          -------------       -----------
ad1.example/ORG/Users    True Bob       Smith   bob.smith      Sales      bob.smith@ad1.example 01/01/2000 12:00:00 

# Specifying domains manually rather than the default defined within the script.
# Default 'Type' is User, no need to specify that parameter if searching users.

.EXAMPLE
.\Search-AdObjects.ps1 -Search *sales*

ParentCanonical       Enabled GivenName Surname SamAccountName Department EmailAddress           LastLogonDate       Description
---------------       ------- --------- ------- -------------- ---------- ------------           -------------       -----------
ad1.example/ORG/Users    True Bob       Smith   bob.smith      Sales      bob.smith@ad1.example  01/01/2000 12:00:00 
ad1.example/ORG/Users    True Jane      Baker   jane.baker     Pre-sales  jane.baker@ad1.example 01/01/2000 12:00:00 
ad1.example/ORG/Users    True John      Green   john.green     Marketing  john.green@ad1.example 01/01/2000 12:00:00 Interim sales

# Using default domains defined within the script.
# Default 'Type' is User, no need to specify that parameter if searching users.
# Using wildcards before and after the search term to make the query less specific.

.EXAMPLE
.\Search-AdObjects.ps1 -Servers ad1.example, ad2.example -Type Computer -Search '*file server*''

ParentCanonical           Enabled Name IPv4Address OperatingSystem              LastLogonDate       Description
---------------           ------- ---- ----------- ---------------              -------------       -----------
ad1.example/ORG/Computers    True fs01 10.0.0.10   Windows Server 2019 Standard 01/01/2000 12:00:00 ProjectA File Server

# Specifying domains manually rather than the default defined within the script.
# 'Type' needs to be specified as Computer.
# Using quotation marks around any values with spaces.
# Using wildcards before and after the search term to make the query less specific.

.EXAMPLE
.\Search-AdObjects.ps1 -PassThru -Search *sales* | Out-GridView

<PowerShell GridView GUI>

# Using default domains defined within the script.
# Default 'Type' is User, no need to specify that parameter if searching users.
# Using 'PassThru' to allow passing the user object(s) down the pipeline, in this case to Out-GridView
# 'Search' must be populated if using 'PassThru'
# Using wildcards before and after the search term to make the query less specific.
#>

param (
    # Default domains to search are defined here, use the 'Domains' parameter to override - or change the below line
    [Parameter()][Alias('Domains')][ValidateNotNullOrEmpty()][String[]]$Servers = ('ad1.example', 'ad2.example'),
    # Default type of object to search is User, use 'Type' parameter to override
    # TODO add 'Group'
    [Parameter()][ValidateSet('User', 'Computer')][String]$Type = 'User',
    [Parameter()][ValidateNotNullOrEmpty()][String]$Search,
    [Parameter()][Switch]$PassThru
)

function ConvertTo-ParentCanonical {
    param (
        [Parameter(Mandatory, ValueFromPipeline)][String[]]$CanonicalName
    )
    $CanonicalName | ForEach-Object {
        $($_.Substring(0, $($_).lastIndexOf('/')))
    }
}

function Search-AdObjects {
    param (
        [Parameter(Mandatory, ValueFromPipeline)][String[]]$Servers,
        # TODO add 'Group'
        [Parameter(Mandatory, ValueFromPipeline)][ValidateSet('User', 'Computer')][String]$Type,
        [Parameter(Mandatory, ValueFromPipeline)][String]$Search
    )
    foreach ($server in $Servers) {
        switch ($Type) {
            'User' {
                $searchParameters = @{
                    Server     = $server
                    # For info on Active Directory's ANR feature see https://social.technet.microsoft.com/wiki/contents/articles/22653.active-directory-ambiguous-name-resolution.aspx
                    LDAPFilter = "(|(anr=$Search)(department=$Search)(description=$Search))"
                    Properties = 'CanonicalName', 'Enabled', 'GivenName', 'Surname', 'SamAccountName', 'Department', 'EmailAddress', 'LastLogonDate', 'Description'
                }
                $serverObjects = Get-AdUser @searchParameters
            }
            'Computer' {
                $searchParameters = @{
                    Server     = $server
                    # For info on Active Directory's ANR feature see https://social.technet.microsoft.com/wiki/contents/articles/22653.active-directory-ambiguous-name-resolution.aspx
                    LDAPFilter = "(|(anr=$Search)(description=$Search))"
                    Properties = 'CanonicalName', 'Enabled', 'Name', 'IPv4Address', 'OperatingSystem', 'LastLogonDate', 'Description'
                }
                $serverObjects = Get-AdComputer @searchParameters
            }
            # TODO
            'Group' {
                Throw
            }
        }
        if (($serverObjects | Measure-Object).Count -gt 0) {
            Write-Host ("Found {0}(s) matching '{1}' in {2}" -f $Type, $Search, $server) -ForegroundColor Green
            
            switch ($Type) {
                'User' {
                    $serverObjects | Select-Object @{ Name = 'ParentCanonical'; Expression = { $_.CanonicalName | ConvertTo-ParentCanonical } },
                    Enabled, GivenName, Surname, SamAccountName, Department, EmailAddress, LastLogonDate, Description
                }
                'Computer' {
                    $serverObjects | Select-Object @{ Name = 'ParentCanonical'; Expression = { $_.CanonicalName | ConvertTo-ParentCanonical } },
                    Enabled, Name, Location, IPv4Address, OperatingSystem, LastLogonDate, Description
                }
                # TODO
                'Group' {
                    Throw
                }
            }
        }
        else {
            Write-Host ("No {0}s matching '{1}' in {2}" -f $Type, $Search, $server) -ForegroundColor Gray
        }
    }
}

Import-Module -Name ActiveDirectory -ErrorAction Stop

Write-Host ("Searching domains: {0}" -f ($Servers -join ', ')) -ForegroundColor Cyan

# If the $Search is populated, just return the search result
if ($Search) {
    # If $PassThru is present, return the results as an object
    if ($PassThru) {
        Search-AdObjects -Servers $Servers -Type $Type -Search $Search
    }
    # If $PassThru is absent, return the results as a formatted table
    else {
        Search-AdObjects -Servers $Servers -Type $Type -Search $Search | Format-Table -AutoSize
    }
}
# Else prompt the user to type their search, loop indefinitely unless user breaks loop
else {
    if ($PassThru) {
        Throw "'Search' parameter must be defined if using 'PassThru'"
    }
    while ($true) {
        $Search = Read-Host 'Enter a search term, eg. Name, Description, Department. Press Ctrl+C to cancel'
        Search-AdObjects -Servers $Servers -Type $Type -Search $Search | Format-Table -AutoSize
    }
}