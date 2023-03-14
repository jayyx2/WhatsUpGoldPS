# WhatsUpGoldPS

## Description
You need to start using automation to save time. Time is the most precious thing every person has. Start using the WhatsUp Gold REST API to automate administrative tasks, gather data for display elsewhere, integrate WhatsUp Gold with business processes, and much more. We include access to the WhatsUp Gold REST API with every license, including Free Edition. The new PowerShell module, WhatsUpGoldPS, aims to simplify getting value from WhatsUp Gold's REST API. 

Some everyday use cases include updating device maintenance mode settings, creating new devices for monitoring, enabling or disabling monitors, and gathering report data to display in external systems. The REST API is expansive, and this module aims to gain parity with those same operations. Contributions are encouraged and welcome.

I look forward to continuing to add value to WhatsUp Gold together with our customers and partners.

Examples
--------
#Clone a device
#Create a new device
#Call a script to add device to WhatsUp Gold
#Call a script to set maintenance mode

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
Interested in contributing? Read how you can [Contribute](contributing.md) to WhatsUpGoldPS
This project maintains a [Code of Conduct](code-of-conduct.md) that establishes how the project is governed and how everyone involved is expected to behave. You can report unacceptable behavior to [alberino@progress.com](mailto:alberino@progress.com).

## Release History
A detailed release history is contained in the [Change Log](CHANGELOG.md).

## License
WhatsUpGoldPS is provided under the [Apache License 2.0](LICENSE.md).
