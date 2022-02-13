<#
.SYNOPSIS
v0.1
Queries Active Directory for the current version of Exchange Server objects.

.DESCRIPTION
Exchange Server on-premises and its related Active Directory schema store version attributes in multiple locations within Active Directory.
A simple health check is to confirm that the values of certain attributes in specific Exchange Server related AD objects match what they should be.

The manual way of performing these checks is via ADSI Edit (adsiedit.msc), and the locations to check are outlined in the documentation:
https://docs.microsoft.com/en-us/exchange/plan-and-deploy/prepare-ad-and-domains

This script queries Active Directory for the following values (for the domain 'ad1.invalid'):
rangeUpper attribute from the object "CN=ms-Exch-Schema-Version-Pt,CN=Schema,CN=Configuration,DC=ad1,DC=invalid"
objectVersion attribute from the object "CN=Microsoft Exchange,CN=Services,CN=Configuration,DC=ad1,DC=invalid"
objectVersion attribute from each immediate child object within "CN=Microsoft Exchange,CN=Services,CN=Configuration,DC=ad1,DC=invalid"

Check these values against the Microsoft Documentation:
# Exchange Server 2016: https://docs.microsoft.com/en-us/exchange/plan-and-deploy/prepare-ad-and-domains?view=exchserver-2016#exchange-2016-active-directory-versions
# Exchange Server 2019: https://docs.microsoft.com/en-us/exchange/plan-and-deploy/prepare-ad-and-domains?view=exchserver-2019#exchange-2019-active-directory-versions

.PARAMETER Domains
One or more strings, specifying the domains to query.

.INPUTS
None. You cannot pipe objects to Get-AdExchangeVersion.ps1

.OUTPUTS
PSCustomObject of the values from Active Directory, for each domain queried.

.EXAMPLE
.\Get-AdExchangeVersion.ps1 -Domains ad1.invalid, ad2.invalid

Domain      rangeUpper objectVersion (Default) objectVersion (Configuration)        
------      ---------- ----------------------- -----------------------------        
ad1.invalid      15334                   13242 @{name=AD1 Org; objectVersion=16222}
#>
param (
    # Default domains to search are defined here
    [Parameter()][string[]]$Domains = $env:USERDNSDOMAIN
)
foreach ($domain in $domains) {
    # Making each query as efficient as possible by requesting only what we need - smaller the query the quicker the answer
    $AdRootDse = Get-ADRootDSE -Server $domain
    Write-Verbose "Querying $domain for 'rangeUpper' from 'ms-Exch-Schema-Version-Pt'"
    $rangeUpper = Get-ADObject -Server $domain -Filter 'name -eq "ms-Exch-Schema-Version-Pt"' -SearchBase $AdRootDse.schemaNamingContext -Properties rangeUpper | Select-Object rangeUpper
    Write-Verbose "Querying $domain for 'objectVersion' from 'Microsoft Exchange System Objects'"
    $objectVersionDefault = Get-ADObject -Server $domain -Filter 'name -eq "Microsoft Exchange System Objects"' -Properties objectVersion | Select-Object objectVersion
    $configSearchBase = "CN=Microsoft Exchange,CN=Services", $AdRootDse.configurationNamingContext -join ','
    Write-Verbose "Querying $domain for 'objectVersion' from each immediate child of '$configSearchBase'"
    $objectVersionConfig = Get-ADObject -Server $domain -Filter '*' -SearchBase $configSearchBase -SearchScope 1 -Properties name, objectVersion | Select-Object name, objectVersion

    [PSCustomObject] @{
        'Domain'                        = $domain
        'rangeUpper'                    = $rangeUpper.rangeUpper
        'objectVersion (Default)'       = $objectVersionDefault.objectVersion
        'objectVersion (Configuration)' = $objectVersionConfig
    }
}