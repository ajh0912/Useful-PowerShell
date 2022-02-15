<#
.SYNOPSIS
v0.3
Makes the output of Compare-Object easier to read.

.DESCRIPTION
Takes the objects to compare and a name for each.
Turns the Compare-Object 'SideIndicator' into a descriptor.
Outputs the modified Compare-Object result.

.PARAMETER ReferenceName
Short name for the reference object.

.PARAMETER ReferenceObject
Input an object for Compare-Object to reference with.

.PARAMETER DifferenceName
Short name for the difference object.

.PARAMETER DifferenceObject
Input an object for Compare-Object to difference against.

.PARAMETER Property
Property for Compare-Object to compare between the objects.
Defaults to 'Name' if not specified.

.INPUTS
None. You cannot pipe objects to Compare-WithDescriptor.ps1.

.OUTPUTS
PSCustomObject. Modified from the output of Compare-Object.

.EXAMPLE
.\Compare-WithDescriptor.ps1 -ReferenceName AD -ReferenceObject (Import-Csv ad.csv) -DifferenceName RMM -DifferenceObject (Import-Csv rmm.csv)

Name  Comparison Status
----  -----------------
pc102 Exists only in AD
pc106 Exists only in RMM
#>

param (
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][String]$ReferenceName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][Object]$ReferenceObject,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][String]$DifferenceName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][Object]$DifferenceObject,
    [Parameter()][ValidateNotNullOrEmpty()][String]$Property = "Name"
)

function Get-SideDescriptor {
    param (
        [Parameter(Mandatory, ValueFromPipeline)][String]$SideIndicator
    )
    switch ($SideIndicator) {
        "<=" {
            "Exists only in $ReferenceName"
        }
        "=>" {
            "Exists only in $DifferenceName"
        }
        default {
            Throw "Unknown error"
        }
    }
}

$compareResult = Compare-Object -ReferenceObject $ReferenceObject -DifferenceObject $DifferenceObject -Property $Property
$compareResult | Select-Object $Property, @{ Name = "Comparison Status"; Expression = { $_.SideIndicator | Get-SideDescriptor } }