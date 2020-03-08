# AzAutomation-PoshACME

Automatically create and renew [Let’s Encrypt](https://letsencrypt.org/) certificates using Azure Automation and the [Posh-ACME](https://github.com/rmbolger/Posh-ACME) module

## Quick start

To implement this solution in your environment you have to setup your DNS environment the right way. \
Follow [Prepare your DNS infrastructure](PrepareDNS.md) to do this.

Next set all the variables in [DeployRessources.ps1](DeployRessources.ps1) to custom values.

Caution: "BlobStorageName" has to be a [globally unique name](https://docs.microsoft.com/en-us/azure/storage/common/storage-account-overview#naming-storage-accounts) and may only contain lowercase characters and numbers.

The [DeployRessources.ps1](DeployRessources.ps1) is not meant to be executed as one script but is build to follow each region step for step.

### Known issues

The deployment of the "Az.Resources" module sometimes fails the first time. Remove it and try again.

## Presentation

* [German Version](./presentation/Zertifikatsmanagement_mit_Azure_Automation_und_Lets_Encrypt.pdf) presented @ [Hamburg PowerShell Saturday 2020](https://hamburg.pssaturday.eu/)
