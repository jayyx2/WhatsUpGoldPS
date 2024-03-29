# WhatsUpGoldPS

## Description
WhatsUpGoldPS, the new PowerShell module, simplifies tasks like updating maintenance settings, creating devices and gathering report data. With this module, you can use automation to save time with the WhatsUp Gold REST API, which is included in every license — even Free Edition. We welcome your contributions to help achieve full parity with the extensive API functionality. I look forward to continuing to add value to WhatsUp Gold together with customers and partners.

## Support
This module comes with no warranty or support from anyone, and is offered as-is.

## Examples
* [Clone a device](https://github.com/jayyx2/WhatsUpGoldPS/blob/main/examples/Clone_device.ps1) - Use another device as a template to create a new device
* [Create a new device](https://github.com/jayyx2/WhatsUpGoldPS/blob/main/examples/New_device.ps1)
* Enable or disable maintenance mode
* [Make a custom report to display your data anywhere](https://github.com/jayyx2/WhatsUpGoldPS/blob/main/examples/Custom_report.ps1)
* Set device properties
* Set device attributes
* Set group membership
* Trigger events

## Installing
The easiest way to get WhatsUpGoldPS is using the [PowerShell Gallery](https://powershellgallery.com/packages/WhatsUpGoldPS/)!

### Inspecting the module
Best practice is that you inspect modules prior to installing them. You can do this by saving the module to a local path:
``` PowerShell
PS> Save-Module -Name WhatsUpGoldPS -Path <path>
```
### Installing the module
Once you trust a module, you can install it using:
``` PowerShell
PS> Install-Module -Name WhatsUpGoldPS
```
### Updating WhatsUpGoldPS
Once installed from the PowerShell Gallery, you can update it using:
``` PowerShell
PS> Update-Module -Name WhatsUpGoldPS
```
### Uninstalling WhatsUpGoldPS
To uninstall WhatsUpGoldPS:
``` PowerShell
PS> Uninstall-Module -Name WhatsUpGoldPS
```
## Contributing to WhatsUpGoldPS
Interested in contributing? Read how you can [contribute](contributing.md) to WhatsUpGoldPS
This project maintains a [code of conduct](code-of-conduct.md) that establishes how the project is governed and how everyone involved is expected to behave. You can report unacceptable behavior to [jason@wug.ninja](mailto:jason@wug.ninja).

## Release History
A detailed release history is contained in the [Change Log](CHANGELOG.md).

## License
WhatsUpGoldPS is provided under the [Apache License 2.0](LICENSE.md).
