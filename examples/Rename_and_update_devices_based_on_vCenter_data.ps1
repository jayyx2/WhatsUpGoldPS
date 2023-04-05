#Specify the hostname or IP to your vCenter sevver(s)
$vCenterServer = "192.168.23.60"
#Specify the WhatsUp Gold IP Address or Hostname
$WUGServer = "192.168.1.250"

#Set your VMware Cred
if(!$VMwareCred){
    $VMwareCred = (Get-Credential -UserName "administrator@vsphere.local")
}
#Set your WhatsUp Gold Cred
if(!$WUGCred){
    $WUGCred = (Get-Credential -UserName "admin")
}

# Check if the WhatsUpGoldPS module is loaded, and if not, import it
if (-not (Get-Module -Name WhatsUpGoldPS)) {
    Import-Module WhatsUpGoldPS
}

# Check if the VMware modules are loaded, and if not, import it
if (-not (Get-Module -Name VMware.Vim)) {
    Import-Module VMware.Vim
}
if (-not (Get-Module -Name VMware.VimAutomation.Cis.Core)) {
    Import-Module VMware.VimAutomation.Cis.Core
}
if (-not (Get-Module -Name VMware.VimAutomation.Common)) {
    Import-Module VMware.VimAutomation.Common
}
if (-not (Get-Module -Name VMware.VimAutomation.Core)) {
    Import-Module VMware.VimAutomation.Core
}
if (-not (Get-Module -Name VMware.VimAutomation.Sdk)) {
    Import-Module VMware.VimAutomation.Sdk        
}

Connect-VIServer $vCenterServer -Credential $VMwareCred
Connect-WUGServer $WUGServer -Credential $WUGCred
$VMInfo = Get-VM | Get-VMGuest | Select-Object IPAddress, HostName, OSFullName, GuestFamily, GuestId, State, VmId, VmName, Disks, Nics

ForEach($vm in $VMinfo){
    $VMName = $vm.VmName
    $VMIPv4Address = $vm.IPAddress | Where-Object {$_ -match "\b(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b"}
    $OSFullName = $vm.OSFullName
    $GuestFamily = $vm.GuestFamily
    $GuestId = $vm.GuestId
    $VmId = $vm.VmId
    $NmState = $vm.State
    $VmDisks = $vm.Disks
    $VmNics = $vm.Nics
    $DeviceID = Get-WUGDevices -SearchValue "${VMIPv4Address}" -View id
    Set-WUGDeviceProperties -DeviceID $DeviceID -DisplayName $VMName -note "Updated by a cool script. ${VMName}, ${VMIPv4Address}, ${OSFullName}, ${GuestFamily}, ${GuestId}, ${VmId}, ${NmState}, ${VmDisks}, ${VmNics}"
    $DeviceAttributes = Get-WUGDeviceAttributes -DeviceID $DeviceID
    $VendorOSAttributeID = $null
    ForEach($Attribute in $DeviceAttributes){
        if ($Attribute.Name -eq "Vendor_OS") {
            $VendorOSAttributeId = $Attribute.Id
            break
        }
    }    
    if ($VendorOSAttributeId) {
        Write-Host "Vendor_OS attribute found with ID: $VendorOSAttributeId"
        # Perform another API call to update the Vendor_OS attribute
        foreach ($Attribute in $DeviceAttributes) {
            if ($Attribute.Name -eq "Vendor_OS") {
                $updatedAttributes.Vendor_OS = $vm.OSFullName
            }
          # Add additional attribute updates here
        }
        Set-WUGDeviceAttributes -DeviceID $DeviceID -AttributeID $VendorOSAttributeId -Attributes $updatedAttributes
    } else {
        Write-Host "Vendor_OS attribute not found"
    }
    
}