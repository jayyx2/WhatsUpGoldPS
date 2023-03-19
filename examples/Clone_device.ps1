<#
This script clones an existing device in WhatsUp Gold using a template, and 
updates the display name and address of the new device. If any errors occur during the process, 
it handles them and outputs the error message to the console.

1. The script sets a variable $TemplateId using the Get-WUGDevices function, searching for a device
 with the name "WhatsUpGoldPS_Template" and returning its ID.
2. The script then obtains the device template using the Get-WUGDeviceTemplate function and the 
previously obtained Device ID. The result is stored in the $DeviceTemplate variable.
3. Next, the script attempts to create a new device in WhatsUp Gold using the $DeviceTemplate. 
It sets the displayName to "Cloned Device Example" and DeviceAddress to "127.0.0.1". This is done
 within a try-catch block to handle any errors that might occur during the process.
    3.a. If the new device creation is successful, the script outputs a message with the created
     device ID and the template ID used for the creation.
    3.b. If an error occurs while creating the new device, the script writes the error message 
    to the console and stores the error message and stack trace in the $errorMessage variable. The error message is then written to the console.

#>

###Clone device example

#Obtain the Device ID of the device we want to be our template
$TemplateId = Get-WUGDevices -SearchValue "WhatsUpGoldPS_Template" -view id

#Obtain the device template using the Device ID
$DeviceTemplate = Get-WUGDeviceTemplate -DeviceID $TemplateId.id

#Try to create the new device using the template
try{
    $NewId = Add-WugDevice -Template $DeviceTemplate -displayName "Cloned Device Example" -DeviceAddress "127.0.0.1"
    Write-Host "We created deviceID $($NewId.idmap.resultId) using templateId $($NewId.idMap.templateId)"
} 
#If it fails, write the error message
catch {
    Write-Error "Error: $_"
    $errorMessage = "Error setting device properties: $($_.Exception.Message)`nStackTrace: $($_.ScriptStackTrace)"
    Write-Error $errorMessage
}