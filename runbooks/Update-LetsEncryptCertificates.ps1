<#
.SYNOPSIS
    Renew Let's Encrypt certificates

.DESCRIPTION
    Renew Let's Encrypt certificates if they are within the renewal window.

    Without any parameters this scripts tries to update all certificates.

.PARAMETER AllOrders
    Update all certificate orders in the current account

    Default: $true

.PARAMETER AllAccounts
    Update all certificate orders of all possible accounts

    Default: $true

.PARAMETER OnlyDomain
    Only update the certificate order for a specific domain

.PARAMETER NewKey
    Generate a new private key if the certificate is actually renewed

    Default: $true

.PARAMETER Force
    Force the renewal of the certificates even if the renewal window is not yet reached
    Use with caution and only if really necessary

    Default: $false

.EXAMPLE
An example

.NOTES
    Copyright: (c) 2020 Fabian Bader
    License: MIT https://opensource.org/licenses/MIT

#>
param (
    [Parameter(Mandatory = $false)]
    [bool]$AllOrders = $true,

    [Parameter(Mandatory = $false)]
    [bool]$AllAccounts = $true,

    [Parameter(Mandatory = $false)]
    [string]$OnlyDomain = "",

    [Parameter(Mandatory = $false)]
    [bool]$NewKey = $true,

    [Parameter(Mandatory = $false)]
    [bool]$Force = $false
)

#region Initialize variables
$StorageContainerSASToken = Get-AutomationVariable -Name 'StorageContainerSASToken'
$BlobStorageName = Get-AutomationVariable -Name 'BlobStorageName'
#endregion

#region Connect to Azure and retrieve access token
$connection = Get-AutomationConnection -Name 'AzureRunAsConnection'
Connect-AzAccount -ServicePrincipal -Tenant $connection.TenantID -ApplicationId $connection.ApplicationID -CertificateThumbprint $connection.CertificateThumbprint | Out-Null

$currentAzureContext = Get-AzContext
$azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
if (-not $azProfile.Accounts.Count) {
    Write-Error "Ensure you have logged in (Connect-AzAccount) before calling this function."
}
$profileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($azProfile)
$accessToken = ($profileClient.AcquireAccessToken($currentAzureContext.Subscription.TenantId)).AccessToken
#endregion

#region Setup the posh-acme directory and configuration
# Download current posh-acme configuration and certificates
try {
    $AzStorageContext = New-AzStorageContext -SasToken $StorageContainerSASToken -StorageAccountName $BlobStorageName
} catch {
    Write-Error "Could not setup to azure storage context for $BlobStorageName"
    Throw
}

#Define working directory
$workingDirectory = Join-Path -Path "." -ChildPath "posh-acme"
try {
    # Download posh-acme configuration zip
    Get-AzStorageBlobContent -Container "posh-acme" -Blob "posh-acme.zip" -Destination . -Context $AzStorageContext -ErrorAction Stop | Out-Null
    # Expand zip file
    Expand-Archive ".\posh-acme.zip" -DestinationPath .
    Remove-Item -Force .\posh-acme.zip | Out-Null
    Write-Output "Downloaded and expanded ZIP file with posh-acme configuration"
} catch {
    $_
    # Storage blob not found, create new folder
    New-Item -Path $workingDirectory -ItemType Directory | Out-Null
    Write-Output "Use new configuration directory, no posh-acme configuration found"
}
#endregion

#region Set posh-acme working directory to downloaded configuration
$env:POSHACME_HOME = $workingDirectory
Import-Module Posh-ACME -Force
#endregion

#region Renew certificates
# Which domains and accounts should be renewed
# All verbose output will be redirected to default output
$GLOBAL:VerbosePreference = "Continue"
$paPluginArgs = @{
    AZSubscriptionId = $currentAzureContext.Subscription.Id
    AZAccessToken    = $accessToken;
}

if ( $AllAccounts ) {
    "Going to renew all certificates in all accounts"
    Submit-Renewal -AllAccounts -NewKey:$NewKey -Force:$Force -PluginArgs $paPluginArgs 4>&1
} elseif ( $AllOrders ) {
    "Going to renew all certificates for the last used account"
    Submit-Renewal -AllOrders -NewKey:$NewKey -Force:$Force -PluginArgs $paPluginArgs 4>&1
} else {
    "Going to renew only certificate for domain `"$OnlyDomain`" in current account"
    Submit-Renewal -MainDomain $OnlyDomain -NewKey:$NewKey -Force:$Force -PluginArgs $paPluginArgs 4>&1
}
$GLOBAL:VerbosePreference = "SilentlyContinue"
#endregion

#region Upload changed posh-acme configuration and certificates
## Create ZIP file of configuration
Compress-Archive -Path $workingDirectory -DestinationPath $env:TEMP\posh-acme.zip -CompressionLevel Fastest -Force
Set-AzStorageBlobContent -File $env:TEMP\posh-acme.zip -Container "posh-acme" -Blob "posh-acme.zip" -BlobType Block -Context $AzStorageContext -Force | Out-Null
Write-Output "posh-acme configuration was backed up to the storage container 'posh-acme'"
#endregion