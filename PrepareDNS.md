# Prepare your DNS infrastructure

## The environment

The Domain pssaturday.eu is managed by the networking department in my company. They use a DNS server provider not capable of any automation efforts whatsoever. Every DNS entry has to be created manually.

For the Domain name azuredemo.pssaturday.eu I would like to use a Let's encrypt certificate and cannot rely on manual created DNS entries, and since I want to use use a wildcard certificate I cannot use HTTP to verify my domain ownership.

They can't switch over to another DNS provider for the root domain, so we will create another sub domain name which can be moved to another Azure DNS for automation.  
This could also be a completely different domain name, which your networking department has no use for anymore.

## Redirection of Let's Encrypt validation

The domains I would like to create a Let's encrypt certificate for are "*.azuredemo.pssaturday.eu" and "azuredemo.pssaturday.eu" .  
Let's encrypt will use "_acme-challenge.azuredemo.pssaturday.eu" as the domain name to verify domain ownership.

My network department has to create a DNS records of the type CNAME
| DNS Name | Type | Target |
| --- | --- | --- |
| _acme-challenge.azuredemo.pssaturday.eu | CNAME | _acme-challenge.azuredemo.pssaturday.eu.validation.pssaturday.eu |

## Azure DNS Zone

The subdomain "validation.pssaturday.eu" will be under control of the Azure DNS.  
For this the networking department has to create multiple NS records to redirect queries to those DNS servers.

| DNS Name | Type | Target |
| --- | --- | --- |
| validation.pssaturday.eu | NS | ns1-09.azure-dns.com. |
| validation.pssaturday.eu | NS | ns2-09.azure-dns.net. |
| validation.pssaturday.eu | NS | ns3-09.azure-dns.org. |
| validation.pssaturday.eu | NS | ns4-09.azure-dns.info. |

The correct DNS NS names for your setup will be provided in the DeployResources.ps1 script.  
The . at the end of the name is important, do not remove it!

### Check the DNS setup

```powershell
Resolve-DnsName -Server 1.1.1.1 -Type CNAME -Name _acme-challenge.azuredemo.pssaturday.eu
Resolve-DnsName -Server 1.1.1.1 -Type NS -Name validation.pssaturday.eu
```
