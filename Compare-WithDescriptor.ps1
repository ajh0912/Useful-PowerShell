<#
.SYNOPSIS
Makes the output of Compare-Object easier to read.

.DESCRIPTION
Runs Compare-Object on the given ReferenceObject and DifferenceObject.
Turns the Compare-Object 'SideIndicator' into a descriptor, using the appropriate name from ReferenceName or DifferenceName.
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

.PARAMETER IncludeEqual
If specified, calls Compare-Object with the IncludeEqual switch.

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

.EXAMPLE
.\Compare-WithDescriptor.ps1 -ReferenceName AD -ReferenceObject (Import-Csv ad.csv) -DifferenceName RMM -DifferenceObject (Import-Csv rmm.csv) -IncludeEqual

Name  Comparison Status
----  -----------------
pc101 Exists in both AD and RMM
pc102 Exists only in AD
pc103 Exists in both AD and RMM
pc104 Exists in both AD and RMM
pc105 Exists in both AD and RMM
pc106 Exists only in RMM
#>

param (
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][String]$ReferenceName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][Object]$ReferenceObject,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][String]$DifferenceName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][Object]$DifferenceObject,
    [Parameter()][ValidateNotNullOrEmpty()][String]$Property = 'Name',
    [Parameter()][Switch]$IncludeEqual
)

function Get-SideDescriptor {
    param (
        [Parameter(Mandatory, ValueFromPipeline)][String]$SideIndicator
    )
    switch ($SideIndicator) {
        '<=' {
            'Exists only in {0}' -f $ReferenceName
            Break
        }
        '=>' {
            'Exists only in {0}' -f $DifferenceName
            Break
        }
        '==' {
            'Exists in both {0} and {1}' -f $ReferenceName, $DifferenceName
            Break
        }
    }
}

$compareParams = @{
    ReferenceObject  = $ReferenceObject
    DifferenceObject = $DifferenceObject
    Property         = $Property
}
if ($IncludeEqual) {
    # If the $IncludeEqual switch was used, add -IncludeEqual:$true to $compareParams
    $compareParams['IncludeEqual'] = $true
}

$compareResult = Compare-Object @compareParams
$compareResult | Select-Object $Property, @{ Name = 'Comparison Status'; Expression = { $_.SideIndicator | Get-SideDescriptor } }