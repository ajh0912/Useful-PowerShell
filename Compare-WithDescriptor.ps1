# AH v0.1
<#
.SYNOPSIS
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
All parameters can be piped in, as long as they are named elements.

.OUTPUTS
PSCustomObject. Modified from the output of Compare-Object.

.EXAMPLE
PS> .\Compare-WithDescriptor.ps1 -ReferenceName "AD" -ReferenceObject (Import-Csv "ad.csv") -DifferenceName "RMM" -DifferenceObject (Import-Csv "rmm.csv") -Property Name

Name  Comparison Status
----  -----------------
pc102 Exists only in AD
pc106 Exists only in RMM
#>

param (
    [Parameter(Mandatory, ValueFromPipeline)][string]$ReferenceName,
    [Parameter(Mandatory, ValueFromPipeline)][object]$ReferenceObject,
    [Parameter(Mandatory, ValueFromPipeline)][string]$DifferenceName,
    [Parameter(Mandatory, ValueFromPipeline)][object]$DifferenceObject,
    [Parameter(Mandatory, ValueFromPipeline)][string]$Property = "Name"
)

function Get-SideDescriptor {
    param (
        [Parameter(Mandatory, ValueFromPipeline)][string]$SideIndicator
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

$result = Compare-Object -ReferenceObject $ReferenceObject -DifferenceObject $DifferenceObject -Property $Property
$result | Select-Object $Property, @{ Name = "Comparison Status"; Expression = { $_.SideIndicator | Get-SideDescriptor } }