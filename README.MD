# WhatsUpGoldPS

## Description
Use automation to save time with the WhatsUp Gold REST API, included in every license—even Free Edition. The new PowerShell module, WhatsUpGoldPS, simplifies tasks like updating maintenance settings, creating devices, and gathering report data. Contributions are welcome to achieve full functionality parity. I look forward to continuing to add value to WhatsUp Gold together customers and partners.

## Support
This module comes with no warranty or support from anyone, and is offered as-is.

## Examples
* Clone a device
* Create a new device
* Call a script to add device to WhatsUp Gold
* Call a script to set maintenance mode

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
This project maintains a [code of conduct](code-of-conduct.md) that establishes how the project is governed and how everyone involved is expected to behave. You can report unacceptable behavior to [alberino@progress.com](mailto:alberino@progress.com).

## Release History
A detailed release history is contained in the [Change Log](CHANGELOG.md).

## License
WhatsUpGoldPS is provided under the [Apache License 2.0](LICENSE.md).
