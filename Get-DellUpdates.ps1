<#
.SYNOPSIS
Queries for list of updates available from Dell Command Update. Drivers, firmware & BIOS/UEFI etc.

.DESCRIPTION
Dell Command Update must already be present (installed via .exe, not via Microsoft Store / UWP).

Runs Dell Command Update in 'Scan' mode, which produces an XML report of available updates.
Converts the XML report to a CSV file written to $env:TEMP.
Lists available updates on the standard output.

Optionally stores the number of updates for each urgency into a user-defined field of the computer in Datto RMM / CentraStage.

.PARAMETER storeToUDF
If present/true, will convert the XML report into a string containing the number of updates for each urgency.
It will then store this string into a user-defined field for the computer in Datto RMM / CentraStage.
See https://rmm.datto.com/help/en/Content/4WEBPORTAL/Devices/UserDefinedFields.htm
Stores into the user-defined field named in parameter 'customVariable'.

.PARAMETER customVariable
This is the name of the user-defined field used in parameter 'storeToUDF'.
For example, 'Custom1', or 'Custom20'.
Can only be used if parameter storeToUDF is present/true.

.LINK
https://www.dell.com/support/manuals/en-uk/command-update/dellcommandupdate_rg/dell-command-%7C-update-command-line-interface?guid=guid-c8d5aee8-5523-4d55-a421-1781d3da6f08&lang=en-us
#>
[CmdletBinding(DefaultParameterSetName = 'default')]
param (
    [Parameter(ParameterSetName = 'UDF')]
    [ValidateNotNullOrEmpty()]
    [switch]$storeToUDF,
    
    [Parameter(ParameterSetName = 'UDF')]
    [ValidateNotNullOrEmpty()]
    [string]$customVariable = 'Custom10'
)

$programFiles = if ([Environment]::Is64BitOperatingSystem) {
    ${env:ProgramFiles(x86)}
}
else {
    $env:ProgramFiles
}

$dateTime = Get-Date -Format FileDateTimeUniversal
$dcuExePath = Join-Path -Path $programFiles -ChildPath 'Dell\CommandUpdate\dcu-cli.exe'
# The -report argument of 'dcu-cli.exe /scan' is hard coded to not allow C:\Windows\Temp
# So unfortunately $env:TEMP does not work when running as NT AUTHORITY\SYSTEM, instead we'll use this directory
$dcuReportDirectory = 'C:\ProgramData\Dell'
$dcuReportPath = Join-Path -Path $dcuReportDirectory -ChildPath 'DCUApplicableUpdates.xml'

try {
    Start-Process -FilePath $dcuExePath -ArgumentList "/scan -report=`"$dcuReportDirectory`"" -Verbose -Wait
}
catch {
    # Writing errors to standard error and standard output as some RMM platforms split these into different windows
    Write-Error $_
    Write-Host 'Error: Dell Command Update failed to check updates'
    Write-Error 'Error: Dell Command Update failed to check updates' -ErrorAction Stop
}

[xml]$dcuReport = Get-Content $dcuReportPath
Remove-Item $dcuReportPath -Force

$updateObject = $dcuReport.updates.update | Select-Object -Property name, version, date, urgency, type, category, file, LocalName, bytes
if ($updateObject) {
    Write-Host 'Updates available:'
    $updateObject | Format-List
    
    $updatesCsvPath = Join-Path -Path $env:TEMP -ChildPath "$dateTime-DellUpdates.csv"
    $updateObject | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $updatesCsvPath
}
else {
    Write-Host 'No updates available'
    $updateStatus = 'No updates available'
}
if ($storeToUDF) {
    # Group updates by urgency status and turn into a single string for storing in a user-defined field in Datto RMM / CentraStage
    $updateStatusString = ($updateObject | Group-Object -Property urgency | ForEach-Object { Write-Output ("{0} {1}" -f $_.Count, $_.Name) }) -join ', '
    $updateStatus = 'Updates available:', $updateStatusString -join ' '
    
    # Store $updateStatus into the user-defined field
    New-ItemProperty -Path HKLM:\SOFTWARE\CentraStage -Name $customVariable -Value $updateStatus -PropertyType String -Force | Out-Null
}