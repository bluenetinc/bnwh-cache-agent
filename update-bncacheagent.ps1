<# 
.SYNOPSIS 
 Update the agent with the latest version from the repository
 
 
.DESCRIPTION 
 Setup and maintain agent scripts with latest version from the git repository.
 

.NOTES 
┌─────────────────────────────────────────────────────────────────────────────────────────────┐ 
│ update-bncacheagent.ps1                                                                     │ 
├─────────────────────────────────────────────────────────────────────────────────────────────┤ 
│   DATE        : 5.28.2019 				               		     			    │ 
│   AUTHOR      : Paul Drangeid 			                   				    │ 
│   SITE        : https://github.com/bluenetinc/bnwh-cache-agent                               │ 
└─────────────────────────────────────────────────────────────────────────────────────────────┘ 
#> 

$companyname="Blue Net Inc"
$reporoot="https://raw.githubusercontent.com/bluenetinc"
$path = $("$Env:Programfiles\$companyname")
$localtz=Get-TimeZone | Select Id -ExpandProperty Id
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function ConvertUTC {
param($time, $fromTimeZone)
  $oFromTimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById($fromTimeZone)
  $utc = [System.TimeZoneInfo]::ConvertTimeToUtc($time, $oFromTimeZone)
  return $utc
} # End ConvertUTC


function ConvertUTCtoLocal{
param([String] $UTCTime)
$strCurrentTimeZone = (Get-WmiObject win32_timezone).StandardName
$TZ = [System.TimeZoneInfo]::FindSystemTimeZoneById($strCurrentTimeZone)
$LocalTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($UTCTime, $TZ)
return $LocalTime
} # End ConvertUTCtoLocal

Function get-updatedgitfile([string]$reponame,[string]$repofile,[string]$localfilename){
      # This function will query github API at the provided $reponame and $repofile and download if the $localfilename is older or missing.
      # NOTE: unauthentication API queries to github (like this one) are rate-limited to 60 per hour (per IP address)
      # So be sure you are only checking for a few files, and if it is a scheduled job, be sure you won't exceed this limit.
      # You could add authenitcation to this function to avoid the 60/hr rate limitation.

      $githuburl="https://api.github.com/repos/$reponame/commits?path=$repofile&page1&per_page=1"
      Try{
            $Restresult=(Invoke-RestMethod $githuburl -Method 'Get' -Headers @{Accept = "application/json"} -ErrorVariable RestError -ErrorAction SilentlyContinue -TimeoutSec 30)
      }
      Catch {
            $ErrorMessage = $_.Exception.Message
            if ($_.Exception.ItemName -like '*rate limit exceeded*') {
                  Write-Warning "`nExceeded rate limit when querying github API: $githuburl"
                  return $false
            }

            if ($ErrorMessage -eq 'Unable to connect to the remote server'){
                  Write-Warning "`nUnable to connect to the remote server $githuburl"
                  return $false
            }
            write-host "Error Message $ErrorMessage `nFailed Item:$_.Exception.ItemName `nhttp Response:$_.Exception.Response`n"
                  return $false
      }
      #Get the date of the last commit for the repository file requested.
      [datetime]$therepofiledate=$Restresult.commit[0].author.date | get-date -Format "yyyy-MM-ddTHH:mm:ss"
      If (Test-Path -path $localfilename) {
            $lastModifiedDate = (Get-Item $localfilename).LastWriteTime | get-date -Format "yyyy-MM-ddTHH:mm:ss"
            $localfiletime = ConvertUTC $lastModifiedDate $localtz
      if ($localfiletime -ge $therepofiledate){
      }#end if (local file exists, and is the same or newer datestamp than that of the repository)
      else {
            write-host "$repofile will be updated..."
            $downloadfile=$true
      }#end else (file exists, but is older than the one in the repository)
      
      }#end if (the file DOES exists in the expected local path)

      else {
            $localtest="$repofile is not present and will be downloaded from the repository"
            $downloadfile=$true
      }# end else (local file doesn't exist in the expected local path)     
      Write-host $localtest
      
            if ($downloadfile -eq $true) {
            write-host "Downloading $repofile ($therepofiledate) from https://raw.githubusercontent.com/$reponame/master/$repofile"
            $dlurl="https://raw.githubusercontent.com/$reponame/master/$repofile"
            $client = new-object System.Net.WebClient
            Try{
            Write-Host "Gonna download $dlurl to $localfilename"
            $dlresult = $client.DownloadFile($dlurl,$localfilename) 
            }
            Catch{
            $ErrorMessage = $_.Exception.Message
            $FailedItem = $_.Exception.ItemName
            $error[0].Exception.ToString()
            Write-Host $ErrorMessage
            Write-Host $FailedItem
            write-host "the error is "$error[0].Exception.ToString()
            }
      
            $localtimestamp = ConvertUTCtoLocal $therepofiledate | get-date
            #Convert the UTC of the repo file to the localtime, then set the local file's lastmodified property to the proper timestamp
            Get-ChildItem  $localfilename | % {$_.LastWriteTime = $localtimestamp}
            }
      }# End Function get-updatedgitfile


If(!(test-path $path))
{
      New-Item -ItemType Directory -Force -Path $path
}

$path = $("$Env:Programfiles\$companyname\Caching Agent")
If(!(test-path $path))
{
      New-Item -ItemType Directory -Force -Path $path
}

$rpath = "bluenetinc/n4j-pswrapper"
$rfile = "set-n4jcredentials.ps1"
$lfile = "C:\Program Files\Blue Net Inc\Caching Agent\set-n4jcredentials.ps1"

get-updatedgitfile $rpath $rfile $lfile
$rpath = "bluenetinc/bnwh-cache-agent"

get-updatedgitfile $rpath "get-datawarehouse-cache.ps1" "$path\get-datawarehouse-cache.ps1"
get-updatedgitfile $rpath "get-vmware-data.ps1" "$path\get-vmware-data.ps1"
get-updatedgitfile $rpath "update-bncacheagent.ps1" "$path\update-bncacheagent.ps1"
get-updatedgitfile $rpath "get-dns.ps1" "$path\get-dns.ps1"
$rpath = "bluenetinc/graph-commit"
get-updatedgitfile $rpath "bg-sharedfunctions.ps1" "$path\bg-sharedfunctions.ps1"

exit

if ($env:Path -notlike "*$path*"){
      # If $path is not in the environment path variable, add it.
$env:Path += ";$path"
}
