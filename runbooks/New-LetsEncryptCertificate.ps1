<#
.SYNOPSIS
    Request new Let's Encrypt certificate and store it in a secured storage blob.

.DESCRIPTION
    Request new Let's Encrypt certificate and store the certificate,
    the private key and all other artefacts in a secured storage blob.
    
.PARAMETER Domains
    Define the SAN value for the certificate.
    Separate multiple domain names by either , or ;

    Wildcard certificate names are allow e.g. *.pssaturday.eu

.PARAMETER ACMEContact
    Overwrite the contact defined in the Azure Automation account

.PARAMETER UseCNAMEDnsAliasValidation
    Use CNAME DNS validation for the _acme-challenge DNS record instead of 

    Default: $true

.PARAMETER UseFixedCNAMEDnsAliasDomain
    Set DNS zone which should be used for CNAME DNS validation.

    Default: Use the first DNS Zone the Azure Automation account has access to

.EXAMPLE
    # New-LetsEncryptCertificate -Domains "*.pssaturday.eu, pssaturday.eu"

    Request a certificate with the wildcard domain "*.pssaturday.eu" and "pssaturday.eu".
    The default ACME contact of the current Azure Automation account is used.
    DNS validation is performed by following the CNAME value of the _acme-challenge DNS record
    to the first DNS zone the Azure Automation account has access to.

.NOTES
    Copyright: (c) 2020 Fabian Bader
    License: MIT https://opensource.org/licenses/MIT

#>
param (
    [Parameter(Mandatory = $true)]
    [string]$Domains,

    [Parameter(Mandatory = $false)]
    [string]$ACMEContact,

    [Parameter(Mandatory = $false)]
    [bool]$UseCNAMEDnsAliasValidation = $true,

    [Parameter(Mandatory = $false)]
    [string]$UseFixedCNAMEDnsAliasDomain = ""
)

#region Initialize variables
$PAServer = Get-AutomationVariable -Name 'PAServer'
if ([string]::IsNullOrWhiteSpace($ACMEContact)) {
    $ACMEContact = Get-AutomationVariable -Name 'ACMEContact'
}
$StorageContainerSASToken = Get-AutomationVariable -Name 'StorageContainerSASToken'
$BlobStorageName = Get-AutomationVariable -Name 'BlobStorageName'
$PfxPass = Get-AutomationVariable -Name 'PfxPass'
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

#region Define Domain and DNS validation Zone if option is true
if ($UseCNAMEDnsAliasValidation) {
    # Get DNS zones possible to use for validation
    $DNSZones = Get-AzResource -ResourceType "Microsoft.Network/dnszones"
    if ([string]::IsNullOrWhiteSpace($UseFixedCNAMEDnsAliasDomain)) {
        # Use a fixed DNS Domain for validation
        $DNSZone = $DNSZones | Where-Object Name -eq $UseFixedCNAMEDnsAliasDomain | Select-Object -First 1 -ExpandProperty Name
        if ([string]::IsNullOrWhiteSpace($DNSZone) ) {
            Write-Output "Could not find a DNS zone with the name $UseFixedCNAMEDnsAliasDomain"
            $DomainValidation = $DNSZones | Select-Object -First 1 -ExpandProperty Name
        }
    } else {
        # Use first possible DNS Zone
        $DomainValidation = $DNSZones | Select-Object -First 1 -ExpandProperty Name
    }
    Write-Output "DNS zone `"$DomainValidation`" will be used for validation"
    # Split certificate names by comma or semicolon
    $DomainsArray = $Domains.Replace(',', ';') -split ';' | ForEach-Object { $_.Trim() }
    # Add _acme-challenge and validation domain to the DNS name
    $DomainValidationArray = $Domains.Replace(',', ';') -split ';' | ForEach-Object { "_acme-challenge." + $_.Trim() + ".$($DomainValidation)" }
    $DomainValidationArray = $DomainValidationArray | ForEach-Object { $_ -replace '(\.\*)' }
    # Replace wildcard with empty string, since it uses the same DNS record
    Write-Output "Will request certificates for the following domains"
    $DomainsArray
    Write-Output "Will use the following DNS Records for validation:"
    $DomainValidationArray
} else {
    $DomainsArray = $Domains.Replace(',', ';') -split ';' | ForEach-Object { $_.Trim() }
    Write-Output "Will request certificates for the following domains, while using the same domains for validation"
    $DomainsArray
}
#endregion

#region Setup the posh-acme directory and configuration
# Download current posh-acme configuration and certificates
$AzStorageContext = New-AzStorageContext -SasToken $StorageContainerSASToken -StorageAccountName $BlobStorageName

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

#region
# Configure Posh-ACME server to selected environment
Set-PAServer -DirectoryUrl $PAServer

# Configure Posh-ACME account
$account = Get-PAAccount
if ( -not $account ) {
    # Create new account
    $account = New-PAAccount -Contact $ACMEContact -AcceptTOS
    Write-Output "Created new account with contact $ACMEContact"
} elseif ( $account.contact -ne "mailto:$ACMEContact" ) {
    # Update account contact information
    Set-PAAccount -ID $account.id -Contact $ACMEContact
    Write-Output "Updated account contact to $ACMEContact from $($account.contact)"
} else {
    Write-Output "No update to account necessary"
}
#endregion

#region Request new certificate while using alias
# All verbose output will be redirected to default output
$GLOBAL:VerbosePreference = "Continue"
$paPluginArgs = @{
    AZSubscriptionId = $currentAzureContext.Subscription.Id
    AZAccessToken    = $accessToken;
}
if ($UseCNAMEDnsAliasValidation) {
    New-PACertificate -Domain $DomainsArray -DnsPlugin Azure -PluginArgs $paPluginArgs -DnsAlias $DomainValidationArray -PfxPass $PfxPass 4>&1
} else {
    New-PACertificate -Domain $DomainsArray -DnsPlugin Azure -PluginArgs $paPluginArgs -PfxPass $PfxPass 4>&1
}
$GLOBAL:VerbosePreference = "SilentlyContinue"
#endregion

#region Upload changed posh-acme configuration and certificates
## Create ZIP file of configuration
Compress-Archive -Path $workingDirectory -DestinationPath $env:TEMP\posh-acme.zip -CompressionLevel Fastest -Force
Set-AzStorageBlobContent -File $env:TEMP\posh-acme.zip -Container "posh-acme" -Blob "posh-acme.zip" -BlobType Block -Context $AzStorageContext -Force | Out-Null
Write-Output "posh-acme configuration was backed up to the storage container 'posh-acme'"
#endregion

#region Remove temporary files and folders
Remove-Item -Recurse -Force $workingDirectory
Remove-Item -Force $env:TEMP\posh-acme.zip
#endregion