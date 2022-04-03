$arch = (Get-CimInstance Win32_OperatingSystem).OSArchitecture
switch ($arch) {
    '64-bit' { $opArch = 'amd64'; break }
    '32-bit' { $opArch = '386'; break }
    Default { Write-Error "Sorry, your operating system architecture '$arch' is unsupported" -ErrorAction Stop }
}
$installDir = Join-Path -Path $env:ProgramFiles -ChildPath '1Password CLI'
Invoke-WebRequest -Uri "https://cache.agilebits.com/dist/1P/op2/pkg/v2.0.0/op_windows_$($opArch)_v2.0.0.zip" -OutFile op.zip
# Force switch is used to overwrite any previous op.exe file
Expand-Archive -Path op.zip -DestinationPath $installDir -Force
# Get current PATH environment variable, using GetEnvironmentVariable instead of $env:Path so we get the freshest value
$envMachinePath = [System.Environment]::GetEnvironmentVariable('PATH','machine')
# Check if current PATH already contains our 1Password CLI directory
if ($envMachinePath -split ';' -notcontains $installDir){
    # Current PATH didn't contain our 1Password CLI directory - backup current PATH before making changes
    $envMachinePath | Out-File $env:TEMP\$(Get-Date -Format FileDateTimeUniversal)-EnvMachinePath.txt
    # Add the new directory to PATH
    [Environment]::SetEnvironmentVariable('PATH', "$envMachinePath;$installDir", 'Machine')
}
Remove-Item -Path op.zip