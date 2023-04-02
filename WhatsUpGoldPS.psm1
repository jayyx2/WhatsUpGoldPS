$functionFolders = @('functions', 'helpers')
ForEach ($folder in $functionFolders)
{
    $folderPath = Join-Path -Path $PSScriptRoot -ChildPath $folder
    If (Test-Path -Path $folderPath)
    {
        Write-Verbose -Message "Importing from $folder"
        $functions = Get-ChildItem -Path $folderPath -Filter '*.ps1'
        ForEach ($function in $functions)
        {
            Write-Verbose -Message "  Importing $($function.BaseName)"
            . $function.FullName
        }
    }
}
Export-ModuleMember -Function Add-WUGDevice, Add-WUGDevices, Connect-WUGServer, Disconnect-WUGServer, Get-WUGDevice, Get-WUGDevices, Get-WUGDeviceTemplate, Remove-WUGDevice, Remove-WUGDevices, Set-WUGDeviceMaintenance, Get-WUGDeviceProperties, Set-WUGDeviceProperties, ConvertTo-BootstrapTable, Convert-HTMLTemplate