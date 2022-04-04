<#
.SYNOPSIS
Searches for Users, Computers or Groups across multiple Active Directory domains / forests.

.DESCRIPTION
For users, matches are returned based on an OR of: Ambiguous Name Resolution, Department, Description
Searching with wildcards can cast a wider net in your search, for example *mysearch* (although a one-ended wildcard can also be used: *mysearch).
An example of this being useful is a search for '*sales*' would also return those with a department of 'Pre-sales'.
This very wide-net method of matching can also be a detriment, a search for '*ted*' might also return any users with 'converted' or 'created' in their description.

For computers and groups, matches are returned based on an OR of: Ambiguous Name Resolution, Description
See above about wildcards.

Parameters can be optionally specified at execution.
If the 'Search' parameter is not set, the user will be prompted to enter a search term interactively.
After results are returned this way, the user is prompted for another search indefinitely until the script is exited.

.PARAMETER PassThru
Return PSCustomObjects rather than formatting to a table.
Can only be used if 'Search' parameter is populated.

.PARAMETER Server
One or more servers to query. Can be the FQDN of the domain or a specific Domain Controller.

.PARAMETER Type
Type of Active Directory object to search for.

.PARAMETER Search
Term to search for in Active Directory, attributes being searched depend on the object type.

.INPUTS
None. You cannot pipe objects to Search-AdObjects.ps1.

.OUTPUTS
Formatted table of the Active Directory object(s) found.
If using 'PassThru' parameter, returns PSCustomObjects.

.EXAMPLE
.\Search-AdObjects.ps1 -Server ad1.example, ad2.example -Search bob
Searching servers / domains: ad1.example, ad2.example
Found User(s) matching 'bob' in ad1.example
No User(s) matching 'bob' in ad2.example

ParentCanonical       Enabled GivenName Surname SamAccountName Department EmailAddress          LastLogonDate       Description
---------------       ------- --------- ------- -------------- ---------- ------------          -------------       -----------
ad1.example/ORG/Users    True Bob       Smith   bob.smith      Sales      bob.smith@ad1.example 01/01/2000 12:00:00

.EXAMPLE
.\Search-AdObjects.ps1 -Search *sales*
Searching servers / domains: ad1.example, ad2.example
Found User(s) matching '*sales*' in ad1.example
Found User(s) matching '*sales*' in ad2.example

ParentCanonical       Enabled GivenName Surname SamAccountName Department EmailAddress           LastLogonDate       Description
---------------       ------- --------- ------- -------------- ---------- ------------           -------------       -----------
ad1.example/ORG/Users    True Bob       Smith   bob.smith      Sales      bob.smith@ad1.example  01/01/2000 12:00:00
ad1.example/ORG/Users    True Jane      Baker   jane.baker     Pre-sales  jane.baker@ad1.example 01/01/2000 12:00:00
ad2.example/ORG/Users    True John      Green   john.green     Marketing  john.green@ad2.example 01/01/2000 12:00:00 Interim sales

.EXAMPLE
.\Search-AdObjects.ps1 -Server ad1.example, ad2.example -Type Computer -Search '*file server*''

Searching servers / domains: ad1.example, ad2.example
Found Computers(s) matching '*file server*' in ad1.example
No Computers matching '*file server*' in ad2.example

ParentCanonical           Enabled Name IPv4Address OperatingSystem              LastLogonDate       Description
---------------           ------- ---- ----------- ---------------              -------------       -----------
ad1.example/ORG/Computers    True fs01 10.0.0.10   Windows Server 2019 Standard 01/01/2000 12:00:00 ProjectA File Server

.EXAMPLE
.\Search-AdObjects.ps1 -Type Group -Search 'local admin'

Searching servers / domains: ad1.example, ad2.example
Found Group(s) matching 'local admin' in ad1.example
Found Group(s) matching 'local admin' in ad2.example

ParentCanonical                             Name               EmailAddress  GroupScope  GroupCategory Description
---------------                             ----               ------------  ----------  ------------- -----------
ad1.example/ORG/Security Groups/Local Admin Local Admin app01                DomainLocal Security      Members are local administrator on app01
ad2.example/ORG/Security Groups/Local Admin Local Admin sync01               DomainLocal Security      Members are local administrator on sync01

.EXAMPLE
.\Search-AdObjects.ps1 -PassThru -Search *sales* | Out-GridView

<PowerShell GridView GUI>
#>

param (
    # Default servers / domains to search are defined here, use the 'Server' parameter to override - or change the below line
    [Parameter()][Alias('Domain')][ValidateNotNullOrEmpty()][String[]]$Server = ('ad1.example', 'ad2.example'),
    # Default type of object to search is User, use 'Type' parameter to override
    [Parameter()][ValidateSet('User', 'Computer', 'Group')][String]$Type = 'User',
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
        [Parameter(Mandatory, ValueFromPipeline)][String[]]$Server,
        [Parameter(Mandatory, ValueFromPipeline)][ValidateSet('User', 'Computer', 'Group')][String]$Type,
        [Parameter(Mandatory, ValueFromPipeline)][String]$Search
    )
    foreach ($singleServer in $Server) {
        switch ($Type) {
            'User' {
                $searchParameters = @{
                    Server     = $singleServer
                    # For info on Active Directory's ANR feature see https://social.technet.microsoft.com/wiki/contents/articles/22653.active-directory-ambiguous-name-resolution.aspx
                    LDAPFilter = "(|(anr=$Search)(department=$Search)(description=$Search))"
                    Properties = 'CanonicalName', 'Enabled', 'GivenName', 'Surname', 'SamAccountName', 'Department', 'EmailAddress', 'LastLogonDate', 'Description'
                }
                $results = Get-AdUser @searchParameters | ForEach-Object {
                    [PSCustomObject]@{
                        ParentCanonical = $_.CanonicalName | ConvertTo-ParentCanonical
                        Enabled         = $_.Enabled
                        GivenName       = $_.GivenName
                        Surname         = $_.Surname
                        SamAccountName  = $_.SamAccountName
                        Department      = $_.Department
                        EmailAddress    = $_.EmailAddress
                        LastLogonDate   = $_.LastLogonDate
                        Description     = $_.Description
                    }
                }
            }
            'Computer' {
                $searchParameters = @{
                    Server     = $singleServer
                    # For info on Active Directory's ANR feature see https://social.technet.microsoft.com/wiki/contents/articles/22653.active-directory-ambiguous-name-resolution.aspx
                    LDAPFilter = "(|(anr=$Search)(description=$Search))"
                    Properties = 'CanonicalName', 'Enabled', 'Name', 'IPv4Address', 'OperatingSystem', 'LastLogonDate', 'Description'
                }
                $results = Get-AdComputer @searchParameters | ForEach-Object {
                    [PSCustomObject]@{
                        ParentCanonical = $_.CanonicalName | ConvertTo-ParentCanonical
                        Enabled         = $_.Enabled
                        Name            = $_.Name
                        IPv4Address     = $_.IPv4Address
                        OperatingSystem = $_.OperatingSystem
                        LastLogonDate   = $_.LastLogonDate
                        Description     = $_.Description
                    }
                }
            }
            'Group' {
                $searchParameters = @{
                    Server     = $singleServer
                    # For info on Active Directory's ANR feature see https://social.technet.microsoft.com/wiki/contents/articles/22653.active-directory-ambiguous-name-resolution.aspx
                    LDAPFilter = "(|(anr=$Search)(description=$Search))"
                    Properties = 'CanonicalName', 'Name', 'Mail', 'GroupScope', 'GroupCategory', 'Description'
                }
                $results = Get-AdGroup @searchParameters | ForEach-Object {
                    [PSCustomObject]@{
                        ParentCanonical = $_.CanonicalName | ConvertTo-ParentCanonical
                        Name            = $_.Name
                        EmailAddress    = $_.Mail
                        GroupScope      = $_.GroupScope
                        GroupCategory   = $_.GroupCategory
                        Description     = $_.Description
                    }
                }
            }
        }
        if (($results | Measure-Object).Count -gt 0) {
            Write-Host ("Found {0}(s) matching '{1}' in {2}" -f $Type, $Search, $singleServer) -ForegroundColor Green
            $results
        }
        else {
            Write-Host ("No {0}s matching '{1}' in {2}" -f $Type, $Search, $singleServer) -ForegroundColor Gray
        }
    }
}

Import-Module -Name ActiveDirectory -ErrorAction Stop

Write-Host ("Searching servers / domains: {0}" -f ($Server -join ', ')) -ForegroundColor Cyan

# If the $Search is populated, just return the search result
if ($Search) {
    # If $PassThru is present, return the results as an object
    if ($PassThru) {
        Search-AdObjects -Server $Server -Type $Type -Search $Search
    }
    # If $PassThru is absent, return the results as a formatted table
    else {
        Search-AdObjects -Server $Server -Type $Type -Search $Search | Format-Table -AutoSize
    }
}
# Else prompt the user to type their search, loop indefinitely unless user breaks loop
else {
    if ($PassThru) {
        Throw "'Search' parameter must be defined if using 'PassThru'"
    }
    while ($true) {
        $Search = Read-Host 'Enter a search term, eg. Name, Description, Department. Press Ctrl+C to cancel'
        Search-AdObjects -Server $Server -Type $Type -Search $Search | Format-Table -AutoSize
    }
}