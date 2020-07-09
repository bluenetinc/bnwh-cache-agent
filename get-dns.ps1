<# 
.SYNOPSIS 
 PowerShell agent to collect data and submit to the neo4j database server
 or to the datawarehouse via the -api switch (used in conjunction with get-datawarehouse-cache.ps1)
  
.DESCRIPTION 
 Identify ActiveDirectory DNS servers (nslookup query), query the zones and records
 generate an import cypher file
 

.NOTES 
┌─────────────────────────────────────────────────────────────────────────────────────────────┐ 
│ get-dns.ps1                                                                                 │  
├─────────────────────────────────────────────────────────────────────────────────────────────┤ 
│   DATE        : 12.26.2019 				               									  │ 
│   AUTHOR      : Paul Drangeid 			                   								  │ 
│   SITE        : https://gitlab.com/pdrangeid/blue-crmgraph                                  │ 
│   PARAMETERS  : -api               :switch indicating cypher results should be sent via api │ 
│                                     a .cypher file will be created for each nameserver      │ 
│                                     and the path to the temporary directory will be returned│ 
│                                                                                             │ 
│               : -verbosity         :Level of on-screen messaging (0-4)                      │ 
│   PREREQS     :                    :DNS RSAT tool must be installed                         │ 
│                                                                                             │ 
│               : This workstation must be able to run query nslookup to determine DNS servers│ 
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘ 
#> 

param (
    [string]$graphdb,
    [string]$graphdblog,
    [int]$verbosity,
    [switch]$api
    )

$global:srccmdline= $($MyInvocation.MyCommand.Name)
$scriptpath = "$env:programfiles\blue net inc\graph-commit\get-cypher-results.ps1"
$WarningPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
if (0 -eq $verbosity){[int]$verbosity=1} #verbosity level is 1 by default
if ([string]::IsNullOrEmpty($graphdblog) -and !([string]::IsNullOrEmpty($graphdb)) ){[string]$graphdblog=$graphdb} #use graphdb if no specific log server is provided
if ([string]::IsNullOrEmpty($graphdb) -and $api -ne $true) {
    #we need a graphdb if you expect to run these!
    Write-Host "If you are not specifying the -api switch you must provide a -graphdb destination server."
    exit
    } 

Write-Host "Verbosity is $verbosity"

Try{. "$PSScriptRoot\bg-sharedfunctions.ps1" | Out-Null}
Catch{
    Write-Warning "I wasn't able to load the sharedfunctions includes (which should live in $PSScriptRoot\). `nWe are going to bail now, sorry 'bout that!"
    Write-Host "Try running them manually, and see what error message is causing this to puke: $PSScriptRoot\bg-sharedfunctions.ps1"
    BREAK
    }

TRY {
 import-module DnsServer | Out-Null
}
CATCH {
    Write-Warning "This powershell module requires the DNS Powershell tools. From PowerShell on Windows Server run the following:"
    Write-Host "`nAdd-WindowsFeature RSAT-DNS-Server "
    Write-Host "`nFor Windows 10 follow these instructions:`nhttps://support.microsoft.com/en-us/help/4055558/rsat-missing-dns-server-tool-in-windows-10`n"
    $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
    $osInfo.ProductType
    if (!$noui -and $osInfo.ProductType -ne 1){
        $answer=yesorno "Would you like the DNS PowerShell module installed on this workstation?" "Missing MS DNS Powershell Module"
        }
        if ($noui){

                $client = new-object System.Net.WebClient
                $dwnloaddst = $env:temp+"\WindowsTH-RSAT_WS_1709-x64.msu"
                $client.DownloadFile("https://download.microsoft.com/download/1/D/8/1D8B5022-5477-4B9A-8104-6A71FF9D98AB/WindowsTH-RSAT_WS_1709-x64.msu",$dwnloaddst)
                $sfile = "C:\Program Files\Blue Net Inc\Caching Agent\installx64.bat"
                $dfile = $env:temp+"\installx64.bat"
                Copy-Item -Path $sfile -Destination $dfile
                $sfile = "C:\Program Files\Blue Net Inc\Caching Agent\unattend_x64.xml"
                $dfile = $env:temp+"\unattend_x64.xml"
                Copy-Item -Path $sfile -Destination $dfile


        }
        if ($answer -eq $true){
        Add-WindowsFeature RSAT-DNS-Server
        }
    if ($api){
        return $False
    }
    BREAK
}

$ErrorActionPreference = 'Continue'

function New-TemporaryDirectory() {
    $parent = [System.IO.Path]::GetTempPath()
    [string] $name = [System.Guid]::NewGuid()
    New-Item -ItemType Directory -Path (Join-Path $parent $name)
    #return $(-join($parent,$name))
}

Function GetDnsZones($DNSServer,$ipaddress)
{
show-onScreen $("Enumerating DNS Zones from $DNSServer ($ipaddress)") 1
$Zones = @(Get-DnsServerZone -ComputerName $DNSServer) 3>$null

#Mark existing records as unvalidated:
$tmp= -join($tmpdir,"\",$DNSServer,"-",$rootdomain,".cypher")
$unvalidated=-Join("MERGE (s:Dnsserver {domain:'$rootdomain',name:'$DNSServer'}) WITH s MATCH (er:Dnsrecord)-[:IN_DNS_ZONE]->(z:Dnszone)-[:ZONE_DNS_SERVER]->(s) SET s.ipaddress='$ipaddress',er.unvalidated=TRUE,z.unvalidated=TRUE;`n")
$unvalidated | Out-File $tmp 

ForEach ($Zone in $Zones) {
$DNSOutput=-join("MATCH (s:Dnsserver {domain:'$rootdomain',name:'$DNSServer'}) MERGE (z:Dnszone { dn:'",$($Zone.DistinguishedName),"'`,domain:'$rootdomain', name:'",$($Zone.ZoneName).ToLower(),"',type:'$($Zone.ZoneType)',adintegrated:$($Zone.IsDsIntegrated),reverse:$($Zone.IsReverseLookupZone)}) MERGE (z)-[:ZONE_DNS_SERVER]->(s) SET s.ipaddress='$ipaddress' REMOVE z.unvalidated`n")
$DNSOutput=-Join($DNSOutput,"MERGE (z)-[:ZONE_DNS_SERVER]->(s)`n")
$DNSOutput | Out-File -Append $tmp 

$ct=""
$DnsRecords=$Zone | Get-DnsServerResourceRecord -ComputerName $DNSServer 3>$null
ForEach ($Record in $DnsRecords) {
$rd=""
if ($Record.RecordType -eq "A") {$rd=$($Record.RecordData.IPv4Address)}
if ($Record.RecordType -eq "AAAA") {$rd=$($Record.RecordData.IPv6Address)}
if ($Record.RecordType -eq "CNAME") {$rd=$($Record.RecordData.HostNameAlias).ToLower()}
if ($Record.RecordType -eq "NS") {$rd=$($Record.RecordData.NameServer).ToLower()}
if ($Record.RecordType -eq "PTR") {$rd=$($Record.RecordData.PtrDomainName)}
if ($Record.RecordType -eq 'MX') {$rd=-Join("[",$Record.RecordData.Preference,"] ",$Record.RecordData.MailExchange)}
if ($Record.RecordType -eq 'SRV') {$rd=-Join("[",$Record.RecordData.Priority,"]","[",$Record.RecordData.Weight,"]","[",$Record.RecordData.Port,"] ",$Record.RecordData.DomainName)}
if ($Record.RecordType -eq 'TXT') {$rd=$($Record.RecordData.DescriptiveText)}
if ($Record.RecordType -eq 'SOA') {$rd=$($Record.RecordData.HostNameAlias)}
if ($rd -ne "") {
$ct=-Join($ct,"MERGE (r:Dnsrecord {name:'",$($Record.HostName).ToLower(),"',type:'",$($Record.RecordType),"',data:'",$($rd),"'})-[:IN_DNS_ZONE]->(z) SET r.timestamp='",$($Record.Timestamp),"',r.ttl='",$($Record.TimeToLive),"' REMOVE r.unvalidated`n")
$ct=-Join($ct,"WITH z`n")
}# end if $rd -ne ""

} # next $Record
$ct=-Join($ct,"RETURN count(z);`n")
$ct | Out-File -Append $tmp 
Show-OnScreen $("Completed $($Zone.ZoneName).ToLower()... Now for the next zone...") 2
} # next $Zone

if ($api -ne $true){
    
    Show-onscreen $("Importing DNS zones and records from $DNSServer via `n$tmp") 1
    Show-onscreen $("$scriptpath -Datasource $graphdb -cypherscript $tmp -logging $graphdblog") 2
    Try{$result = . $scriptpath -Datasource $graphdb -cypherscript $tmp -logging $graphdblog}
    Catch {write-host "Error executing..."}
    Show-onscreen $("Result of Execution $result") 4
    Start-Sleep -Second 3
    Remove-Item $tmp -Force
    }
} # End Function Get-DnsZones

$rootdomain=$((Get-WmiObject Win32_ComputerSystem).Domain).ToLower()

if ($rootdomain -like "WORKGROUP"){
    Write-host -foregroundColor yellow "This computer is not a member of an Active Directory domain.  You must be a domain member for auto-discovery, otherwise provide the parameter -dnsserver [dnshostname]."
    BREAK 
}


$result = $(nslookup -type=NS $rootdomain | findstr /C:"nameserver =")
$tmpdir=$(New-TemporaryDirectory)
ForEach ($nameserver in $($result -split "`r`n"))
{
    $DNSServer=$($nameserver.split("=")[1].trim()).ToLower()
    Show-Onscreen $("Discovered nameserver: $nameserver (of $($result.count) total)") 1

Try {
    $ipaddress=$(Resolve-DnsName -Type A -Name $DNSServer -ErrorAction Stop).IPAddress
    Show-Onscreen $("Querying DNSServer:$DNSServer ($ipaddress)") 1
    }
Catch {Write-Warning "Failed to resolve IP address for $DNSServer.  Check DNS, Firewall, and hostname and try again."
$Error[0].Exception.Message
BREAK
}

Try {
GetDnsZones $DNSServer $ipaddress
}

Catch {
    Write-Warning "Failed to GetDnsZones for $DNSServer ($ipaddress)."
    Write-Host $Error[0].Exception.Message
    BREAK
    }

}# End ForEach $nameserver

if ($api -ne $true){
    Show-Onscreen $("Cleaning up temp files & directories...") 1
    Remove-Item $tmpdir -recurse -Force
    }

    if ($api -eq $true){
        return $tmpdir
        }