<#
.SYNOPSIS
v0.2
Queries Active Directory for the current version of Exchange Server objects.

.DESCRIPTION
Exchange Server on-premises and its related Active Directory schema store version attributes in multiple locations within Active Directory.
A simple health check is to confirm the values of these specifc attributes match what they should be.

The manual way of performing these checks is via ADSI Edit (adsiedit.msc), and the locations to check are outlined in the documentation:
https://docs.microsoft.com/en-us/exchange/plan-and-deploy/prepare-ad-and-domains

This script queries Active Directory for the following values:
rangeUpper, objectVersion (Default), objectVersion (Configuration)

Check these values against the Microsoft Documentation:
# Exchange Server 2016: https://docs.microsoft.com/en-us/exchange/plan-and-deploy/prepare-ad-and-domains?view=exchserver-2016#exchange-2016-active-directory-versions
# Exchange Server 2019: https://docs.microsoft.com/en-us/exchange/plan-and-deploy/prepare-ad-and-domains?view=exchserver-2019#exchange-2019-active-directory-versions

.PARAMETER Servers
One or more strings, specifying the servers to query.
A specific domain contoller can be used, or if the domain FQDN entered then one domain controller in the domain will be queried.

.INPUTS
None. You cannot pipe objects to Get-AdExchangeVersion.ps1

.OUTPUTS
PSCustomObject of the values from Active Directory, for each domain queried.

.EXAMPLE
.\Get-AdExchangeVersion.ps1 -Servers ad1.example, ad2.example

Domain      rangeUpper objectVersion (Default) objectVersion (Configuration)
------      ---------- ----------------------- -----------------------------
ad1.example      15334                   13242                         16222
ad2.example      17003                   13242                         16759

.EXAMPLE
.\Get-AdExchangeVersion.ps1 -Servers dc1.ad1.example, dc2.ad1.example

Domain          rangeUpper objectVersion (Default) objectVersion (Configuration)
------          ---------- ----------------------- -----------------------------
dc1.ad1.example      15334                   13242                         16222
dc2.ad2.example      15334                   13242                         16222

# Querying two domain controllers in the same domain - the values returned should be identical.
# If they are not the same, then there is a domain controller replication problem.

.EXAMPLE
.\Get-AdExchangeVersion.ps1 -Servers ad1.example, ad2.example | Export-Csv -NoTypeInformation -Path "$(Get-Date -f yyyy-MM-dd-HHmm)-AdExchangeVersions.csv"

# '2000-01-01-1200-AdExchangeVersions.csv' file created in current directory
#>

param (
    # Default servers / domains to search are defined here
    [Parameter()][Alias("Domain")][ValidateNotNullOrEmpty()][String[]]$Servers = $env:USERDNSDOMAIN
)

foreach ($server in $Servers) {
    $AdRootDse = Get-ADRootDSE -Server $server
    
    Write-Verbose "Querying $server for 'rangeUpper'"
    $rangeUpper = Get-ADObject -Server $server -Filter 'name -eq "ms-Exch-Schema-Version-Pt"' -SearchBase $AdRootDse.schemaNamingContext -Properties rangeUpper
    
    Write-Verbose "Querying $server for 'objectVersion (Default)'"
    $objectVersionDefault = Get-ADObject -Server $server -Filter 'name -eq "Microsoft Exchange System Objects"' -Properties objectVersion
    
    $configSearchBase = "CN=Microsoft Exchange,CN=Services", $AdRootDse.configurationNamingContext -join ','
    Write-Verbose "Querying $server for 'objectVersion (Configuration)'"
    $objectVersionConfig = Get-ADObject -Server $server -LDAPFilter '(objectClass=msExchOrganizationContainer)' -SearchBase $configSearchBase -Properties objectVersion
    
    [PSCustomObject] @{
        'Domain'                        = $server
        'rangeUpper'                    = $rangeUpper.rangeUpper
        'objectVersion (Default)'       = $objectVersionDefault.objectVersion
        'objectVersion (Configuration)' = $objectVersionConfig.objectVersion
    }
}