#region Environment setup
$ResourceGroupName = "YourResourceGroupName"
$Location = "westeurope"
# DNS zone used for validation purposes (CNAME validation)
$DNSZoneRootDomain = "validation.pssaturday.eu"
$MailContact = "YourMailAddress@Your.Domain"
# Storage Blob Name
# Use something globally unique!
$BlobStorageName = "UniqueStorageBlobName"
# Azure Automation Account
$AutomationAccountName = "LetsEncryptAutomation"
# This password will be used for all exported PFX files created by posh-acme
$PfxPass = "YourSecurePasswordForTheExportedPrivateKeyFiles"

# Don't touch if not sure what you do
$CertificateAssetName = "AzureRunAsCertificate"
$ConnectionAssetName = "AzureRunAsConnection"
$ConnectionTypeName = "AzureServicePrincipal"
# This certificate is used to authenticate the Automation account to Azure
$selfSignedCertNoOfMonthsUntilExpired = 60
# Azure storage account have to be all lowercase and only contain a-z and numbers
$BlobStorageName = $BlobStorageName.ToLower() -replace "[^a-z0-9]"
#endregion

# Connect to Azure
Connect-AzAccount

# Create resource group
$ResourceGroup = New-AzResourceGroup -Name $ResourceGroupName -Location $Location

#region Create DNS Zone
$DNSZone = New-AzDnsZone -Name $DNSZoneRootDomain -ResourceGroupName $ResourceGroupName
# Retrieve DNS server names for the NS records
$DNSZone | Select-Object -ExpandProperty NameServers
# Add those to your custom DNS zone
#endregion

#region BLOB Storage to store the Posh-ACME configuration data
New-AzStorageAccount -Name $BlobStorageName -ResourceGroupName $ResourceGroupName -Location $Location -Kind StorageV2 -SkuName Standard_LRS -EnableHttpsTrafficOnly $true
$storageAccountKey = Get-AzStorageAccountKey -Name $BlobStorageName -ResourceGroupName $ResourceGroupName | Where-Object KeyName -eq "key1" | Select-Object -ExpandProperty Value
$storageContext = New-AzStorageContext -StorageAccountName $BlobStorageName -StorageAccountKey $storageAccountKey
New-AzStorageContainer -Name "posh-acme" -Context $storageContext

#SAS Token for blob access
$SASToken = New-AzStorageContainerSASToken -Name "posh-acme" -Permission rwdl -Context $storageContext -ExpiryTime (Get-Date).AddYears(5)  -StartTime (Get-Date)
#endregion

#region Create a service principal without any permissions assigned
$application = New-AzADApplication -DisplayName "Let's Encrypt Certificate Automation" -IdentifierUris "http://localhost"
$spPrincipal = New-AzADServicePrincipal -ApplicationId $application.ApplicationId -Role $null -Scope $null
$spCredential = New-AzADSpCredential -ServicePrincipalObject $spPrincipal -EndDate (Get-Date).AddYears(5)
#endregion

#region Grant service principal "DNS Zone Contributor" permissions to DNS Zone
New-AzRoleAssignment -ObjectId $spPrincipal.Id -ResourceGroupName $ResourceGroupName -ResourceName $DNSZoneRootDomain -ResourceType "Microsoft.Network/dnszones" -RoleDefinitionName "DNS Zone Contributor"
#endregion

#region Create automation account
New-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName -Location $Location
#endregion

#region Create certificate for Azure Automation Run As Account
$CertificateName = $AutomationAccountName + $CertificateAssetName
$param = @{
    "DnsName"           = $certificateName
    "CertStoreLocation" = "cert:\CurrentUser\My"
    "KeyExportPolicy"   = "Exportable"
    "Provider"          = "Microsoft Enhanced RSA and AES Cryptographic Provider"
    "NotAfter"          = (Get-Date).AddMonths($selfSignedCertNoOfMonthsUntilExpired)
    "HashAlgorithm"     = "SHA256"
}
$Cert = New-SelfSignedCertificate @param
#endregion

#region Export certificate to temp folder
$selfSignedCertPlainPassword = $PfxPass
$CertPassword = ConvertTo-SecureString $selfSignedCertPlainPassword -AsPlainText -Force
$PfxCertPath = Join-Path $env:TEMP ($CertificateName + ".pfx")
$CerCertPath = Join-Path $env:TEMP ($CertificateName + ".cer")
Export-PfxCertificate -Cert ("Cert:\CurrentUser\my\" + $Cert.Thumbprint) -FilePath $PfxCertPath -Password $CertPassword -Force | Write-Verbose
Export-Certificate -Cert ("Cert:\CurrentUser\my\" + $Cert.Thumbprint) -FilePath $CerCertPath -Type CERT | Write-Verbose
#endregion

#region Create Application Credential to use for authentication of RunAs Account
$PfxCert = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @($PfxCertPath, $selfSignedCertPlainPassword)
$param = @{
    "ApplicationId" = $application.ApplicationId
    "CertValue"     = ( [System.Convert]::ToBase64String($PfxCert.GetRawCertData()) )
    "StartDate"     = $PfxCert.NotBefore
    "EndDate"       = $PfxCert.NotAfter
}
$applicationCredential = New-AzADAppCredential @param
#endregion

#region Add certificate to automation account
$param = @{
    "ResourceGroupName"     = $ResourceGroupName
    "AutomationAccountName" = $AutomationAccountName
    "Name"                  = $CertificateAssetName
    "Path"                  = $PfxCertPath
    "Password"              = $CertPassword
    "Exportable"            = $false
}
$AutomationCertificate = New-AzAutomationCertificate @param
#endregion

#region Add Run As Account Connection to automation account
$SubscriptionInformation = Get-AzContext | Select-Object -ExpandProperty Subscription
$ConnectionFieldValues = @{
    "ApplicationId"         = $application.ApplicationId
    "TenantId"              = $SubscriptionInformation.TenantId
    "CertificateThumbprint" = $AutomationCertificate.Thumbprint
    "SubscriptionId"        = $SubscriptionInformation.SubscriptionId
}
$param = @{
    "ResourceGroupName"     = $ResourceGroupName
    "AutomationAccountName" = $AutomationAccountName
    "Name"                  = $ConnectionAssetName
    "ConnectionTypeName"    = $ConnectionTypeName
    "ConnectionFieldValues" = $connectionFieldValues
}
New-AzAutomationConnection @param
#endregion

#region Deploy the necessary module, this will take a while
function New-AutomationModule {
    [CmdletBinding()]
    param (
        [Parameter(
            ValueFromPipeline = $true,
            ValueFromPipelineByPropertyName = $true,
            Mandatory = $true
        )]
        [string]$ModuleName
    )
    process {
        $param = @{
            "ResourceGroupName"     = $ResourceGroupName
            "AutomationAccountName" = $AutomationAccountName
            "Name"                  = $ModuleName
            "ContentLinkUri"        = "https://www.powershellgallery.com/api/v2/package/$ModuleName"
        }
        New-AzAutomationModule @param
        do {
            Start-Sleep 5
            $DeployedModule = Get-AzAutomationModule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $ModuleName
        }
        while ( $DeployedModule.ProvisioningState -eq "Creating" )
        Write-Host "Module $ModuleName in state $($DeployedModule.ProvisioningState)"
    }
}
$NecessaryModules = @( "Az.Accounts", "Az.Resources", "Az.Storage", "Posh-ACME" )
$NecessaryModules | New-AutomationModule


# Test connection within a runbook and this code if you want
# $connection = Get-AutomationConnection -Name 'AzureRunAsConnection'
# Connect-AzAccount -ServicePrincipal -Tenant $connection.TenantID -ApplicationId $connection.ApplicationID -CertificateThumbprint $connection.CertificateThumbprint
# Get-AzResource
# Get-Module -ListAvailable
#endregion

#region Set variables
## Which PAServer to use
$param = @{
    "Name"                  = "PAServer"
    "Description"           = "LE_STAGE = Testing ; LE_PROD = Production"
    "Value"                 = "LE_STAGE"
    "Encrypted"             = $false
    "AutomationAccountName" = $AutomationAccountName
    "ResourceGroupName"     = $ResourceGroupName
}
New-AzAutomationVariable @param

$param = @{
    "Name"                  = "ACMEContact"
    "Description"           = "E-Mail address for this posh-acme account"
    "Value"                 = $MailContact
    "Encrypted"             = $false
    "AutomationAccountName" = $AutomationAccountName
    "ResourceGroupName"     = $ResourceGroupName
}
New-AzAutomationVariable @param

$param = @{
    "Name"                  = "StorageContainerSASToken"
    "Description"           = "SAS Token to access posh-acme files"
    "Value"                 = $SASToken
    "Encrypted"             = $true
    "AutomationAccountName" = $AutomationAccountName
    "ResourceGroupName"     = $ResourceGroupName
}
New-AzAutomationVariable @param

$param = @{
    "Name"                  = "BlobStorageName"
    "Description"           = "Storage account name"
    "Value"                 = $BlobStorageName
    "Encrypted"             = $false
    "AutomationAccountName" = $AutomationAccountName
    "ResourceGroupName"     = $ResourceGroupName
}
New-AzAutomationVariable @param

$param = @{
    "Name"                  = "PfxPass"
    "Description"           = "Password used for exported Pfx file"
    "Value"                 = $PfxPass
    "Encrypted"             = $true
    "AutomationAccountName" = $AutomationAccountName
    "ResourceGroupName"     = $ResourceGroupName
}
New-AzAutomationVariable @param

$param = @{
    "Name"                  = "WriteLock"
    "Description"           = "If set to true no other runbook is allowed to change the posh-ACME configuration data"
    "Value"                 = $false
    "Encrypted"             = $false
    "AutomationAccountName" = $AutomationAccountName
    "ResourceGroupName"     = $ResourceGroupName
}
New-AzAutomationVariable @param
#endregion

#region Deploy Runbooks to Azure Automation account
$Runbooks = Get-ChildItem .\runbooks -Filter *.ps1
foreach ($Runbook in $Runbooks) {
    $param = @{
        "Path"                  = $Runbook.FullName
        "Name"                  = $Runbook.BaseName
        "Type"                  = "PowerShell"
        "Published"             = $true
        "ResourceGroupName"     = $ResourceGroupName
        "AutomationAccountName" = $AutomationAccountName
    }
    Import-AzAutomationRunbook @param
}
#endregion