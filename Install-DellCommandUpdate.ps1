<#
.SYNOPSIS
Installs & configures Dell Command Update. Which can be used to update drivers, firmware & BIOS/UEFI etc.

.DESCRIPTION
Checks if an older version of Dell Command Update is present, if so uninstalls it.
If Dell Command Update is not present, or was an older version,
then downloads the Dell Command Update executable from Dell's website and installs it silently.

Configures Dell Command Update to check for the following updates: BIOS/UEFI, firmware, drivers.
Opts out of Dell telemetry, locks the Dell Command Update application's settings so the user cannot modify.
Sets Dell Command Update to only check for updates when manually invoked (by automation or interactively).

.LINK
https://www.dell.com/support/manuals/en-uk/command-update/dellcommandupdate_rg/dell-command-%7C-update-command-line-interface?guid=guid-c8d5aee8-5523-4d55-a421-1781d3da6f08&lang=en-us
#>

# When specifying a newer DCU version, update the URL as well
# See https://www.dell.com/support/kbdoc/en-uk/000177325/dell-command-update for versions
$dcuTargetVersion = 4.5
$dcuDownloadURL = 'https://dl.dell.com/FOLDER08334841M/4/Dell-Command-Update-Application_W4HP2_WIN_4.5.0_A00_02.EXE'

# Get the computer Vendor, match it case-insensitive against the string 'Dell' (this covers 'Dell', 'Dell Inc.' etc)
$vendor = (Get-WmiObject Win32_ComputerSystemProduct).Vendor
if ($vendor -notmatch 'Dell') {
    Write-Error 'Manufacturer is not Dell, Dell Command Update will not work' -ErrorAction Stop
}

$dcuRegistry = if ([Environment]::Is64BitOperatingSystem) {
    # Wildcard before 'Update' ensures we match when the pipe character is present, and also when missing
    Get-ItemProperty HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* | Where-Object { $_.DisplayName -like 'Dell Command *Update' }
}
else {
    Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* | Where-Object { $_.DisplayName -like 'Dell Command *Update' }
}

$programFiles = if ([Environment]::Is64BitOperatingSystem) {
    ${env:ProgramFiles(x86)}
}
else {
    $env:ProgramFiles
}
$dcuExePath = Join-Path -Path $programFiles -ChildPath 'Dell\CommandUpdate\dcu-cli.exe'

switch ($dcuRegistry.Displayversion) {
    # If an older version of Dell Command Update is already installed, uninstall it
    { $_ -lt $dcuTargetVersion } {
        try {
            Start-Process -FilePath 'msiexec.exe' -ArgumentList "/x$($dcuRegistry.PSChildName) /qn /norestart" -Verbose -Wait
        }
        catch {
            # Writing errors to standard error and standard output as some RMM platforms split these into different windows
            Write-Error $_
            Write-Host ("Failed to uninstall existing Dell Command Update {0}" -f $dcuRegistry.Displayversion)
            Write-Error ("Failed to uninstall existing Dell Command Update {0}" -f $dcuRegistry.Displayversion) -ErrorAction Stop
        }
    }
    # If Dell Command Update is not installed (or was an older version)
    { $_ -ne $dcuTargetVersion } {
        $downloadFile = 'DellCommandUpdateInstaller.exe'
        $downloadPath = Join-Path -Path $env:TEMP -ChildPath $downloadFile
        # Dell servers only allow normal user agents, so we pretend we are Firefox 99 on Windows 10
        $userAgent = 'Mozilla/5.0 (Windows NT 10.0; WOW64; rv:99.0) Gecko/20100101 Firefox/99.0'
        
        try {
            $action = 'download'
            Invoke-WebRequest -UseBasicParsing -Uri $dcuDownloadURL -OutFile $downloadPath -UserAgent $userAgent
            
            $action = 'install'
            # Execute the Dell Command Update installer with silent argument
            Start-Process -FilePath $downloadPath -ArgumentList '/s' -Verbose -Wait
            
            $action = 'disable background service of'
            # Ensure Dell Command Update doesn't run in the background, otherwise it would prompt in userland occasionally
            Set-Service -Name 'DellClientManagementService' -StartupType Manual
            
            $action = 'configure'
            Start-Process -FilePath $dcuExePath -ArgumentList "/configure -restoreDefaults -lockSettings=enable -userConsent=disable -scheduledReboot=5 -updatetype=bios,firmware,driver -silent" -Verbose -Wait
            # -scheduleManual conflicts with other dcu-cli.exe arguments, so must be run on its own
            Start-Process -FilePath $dcuExePath -ArgumentList "/configure -scheduleManual -silent" -Verbose -Wait
        }
        catch {
            # Writing errors to standard error and standard output as some RMM platforms split these into different windows
            Write-Error $_
            Write-Host "Failed to $action Dell Command Update"
            Write-Error "Failed to $action Dell Command Update" -ErrorAction Stop
        }
    }
}