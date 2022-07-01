<# 
.SYNOPSIS 
 PowerShell agent to collect data and submit to the datawarehouse via API
  
.DESCRIPTION 
 The webAPI will identify based on your tenantGUID which data sources, and time periods
 are being requested.  This agent will then query the data source(s), collect the 
 data and submit it via the WebAPI for submision to the data warehouse cache database.
 
.NOTES 
┌─────────────────────────────────────────────────────────────────────────────────────────────┐ 
│ get-datawarehouse-cache.ps1                                                                 │ 
├─────────────────────────────────────────────────────────────────────────────────────────────┤ 
│   DATE        : 6.30.2022				               									  
│   AUTHOR      : Paul Drangeid 			                   								  │ 
│   SITE        : https://github.com/pdrangeid/bnwh-cache-agent                               │ 
│   PARAMETERS  : -subtenant <name of subtenant>    :store settings in subkey for this tenant │ 
│               : -noui                             :Disable user interaction (scheduled job) │ 
│               : -verbosity                        :Level of on-screen messaging (0-4      ) │ 
│               : -whatif                           :Run, but do NOT submit data to the API   │ 
│   PREREQS     : ADSI (Active Directory) Queries:                                            │ 
│               : Domain Controllers must be 2008R2 or newer and running ADWS                 │ 
│               : This workstation must be able to run the PS AD Modules                      │ 
│               : VMware Queries (standalone ESXi host or vCenter):                           │ 
│               : requires RVTools (https://www.robware.net/rvtools/) v 3.11.6 or newer       │ 
│               : Delegated Administrator credentials and MSOL Powershell module              │ 
└─────────────────────────────────────────────────────────────────────────────────────────────┘ 
#> 

param (
    [string]$subtenant,
    [switch]$queryo365,
    [switch]$noui,
    [switch]$querymwp,
    [switch]$whatif,
    [int]$verbosity
    )

$VMwareinitialized = $false
$ErrorActionPreference = 'SilentlyContinue'
Remove-Variable -name apikey | Out-Null
Remove-Variable -name tenantguid | Out-Null
$global:srccmdline= $($MyInvocation.MyCommand.Name)
#$scriptappname = "Blue Net get-datawarehouse-cache"
$baseapiurl="https://api-cache.bluenetcloud.com"
$ScheduledJobName = "Blue Net Warehouse Data Refresh"
$apigetreq="https://api-cache.bluenetcloud.com/api/v1/get-data-requests/"
$apisubmit="https://api-cache.bluenetcloud.com/api/v1/submit-data"
$apierror="https://api-cache.bluenetcloud.com/api/v1/submit-error/"

if ($noui -and $null -eq $verbosity){[int]$verbosity=0} #noui switch sets output verbosity level to 0 by default
if ($whatif -and $null -eq $verbosity){[int]$verbosity=4} #whatif switch sets output verbosity level to 4 by default
if ($null -eq $verbosity){[int]$verbosity=1} #verbosity level is 1 by default

Show-onscreen $("`nLoading includes: $PSScriptRoot\bg-sharedfunctions.ps1") 1
Try{. "$PSScriptRoot\bg-sharedfunctions.ps1" | Out-Null}
Catch{
    Write-Warning "I wasn't able to load the sharedfunctions includes (which should live in the same directory as $global:srccmdline). `nWe are going to bail now, sorry 'bout that!"
    Write-Host "Try running them manually, and see what error message is causing this to puke: $PSScriptRoot\bg-sharedfunctions.ps1"
    Unregister-PSVars
    BREAK
    }

    Function Submit-agenterror([string]$Sectionname,[string]$Errortext,[string]$DSName){
        if ([string]::IsNullOrEmpty($DSName)){$DSName='Not Provided'}
        $ErrorMessage=$("Script:$global:srccmdline`nFunction:$Sectionname`nURL:apiURL`nError:$Errortext")
        $apiurlparms="?TenantGUID="+$tenantguid+"&DataSourceName=$DSName"
        $apiurl=$apierror+$apiurlparms.replace('+','%2b')
        write-host "Submitting Error:"
        $thecontent = (@{"message" = $ErrorMessage} | ConvertTo-Json -Compress)
        Invoke-RestMethod $apiurl -Method 'Post' -Headers @{"x-api-key"=$APIKey;Accept="application/json";"content-type" = "binary"} -ErrorVariable RestError  -Body $thecontent -ErrorAction SilentlyContinue -TimeoutSec 900 
    }# End Function Submit-agenterror

    Prepare-EventLog
    Function Set-CacheSyncJob{

        if (![string]::IsNullOrEmpty($global:targetserver)){
            $global:targetserver = $Env:LOGONSERVER.replace('\','')
        }
        Get-ScheduledTask -TaskName $ScheduledJobName -ErrorAction SilentlyContinue -OutVariable task |Out-Null
        if ($task -and ![string]::IsNullOrEmpty($subtenant)){
        $tenantjobtaskexists = $false
        Write-Host "Checking Subtentant Task Status"
        $task |
        ForEach-Object {
        if ($_.actions.Arguments -like '*'+$subtenant+'*') {
        # Subtenant already has an action in the existing Scheduled Task
        $tenantjobtaskexists = $true
        }
        if (!$tenantjobtaskexists){
            write-host "This subtenant does not yet have an action item as a part of the scheduled task"
            $answer=yesorno "Would you like to schedule this subtenant refresh job to run automatically?" "Schedule data synchronization"
            if ($answer -eq $true){
            $Username = $env:userdomain+"\"+$Env:USERNAME
            $credentials = $Host.UI.PromptForCredential("Task username and password","Provide the password for this account that will run the scheduled task",$Username,$env:userdomain)
            $Password = $Credentials.GetNetworkCredential().Password 
            $Prog = $env:systemroot + "\system32\WindowsPowerShell\v1.0\powershell.exe"
            #$thisuserupn = (get-aduser-server $global:targetserver ($Env:USERNAME)).userprincipalname
            $Opt = '-nologo -noninteractive -noprofile -ExecutionPolicy BYPASS -file "'+$PSScriptRoot+'\get-datawarehouse-cache.ps1" -noui -subtenant "'+$subtenant+'"'
            if ($queryo365 -eq $true){$Opt = "$Opt -queryo365"}
            if ($querymwp -eq $true){$Opt = "$Opt -querymwp"}
            $task | ForEach-Object {
                $action = $_.actions
                $action += New-ScheduledTaskAction -Execute $Prog -Argument $Opt -WorkingDirectory $PSScriptRoot
                Set-ScheduledTask -TaskName $ScheduledJobName -Action $action -User $Username -Password $Password
            }# End ForEach-Object (updating tasks)
            }# End User answered YES to adding this task
        }# End subtenantjob action is missing
        }# End ForEach
        }# End have subtenant AND scheduled task
        
        if (!$task) {
        # task does not exist, otherwise $task contains the task object
        $answer=yesorno "Would you like to schedule this agent to run automatically?" "Schedule data synchronization"
        if ($answer -eq $true){
            $Username = $env:userdomain+"\"+$Env:USERNAME
            $credentials = $Host.UI.PromptForCredential("Task username and password","Provide the password for this account that will run the scheduled task",$Username,$env:userdomain)
            $Password = $Credentials.GetNetworkCredential().Password 
            $Prog = $env:systemroot + "\system32\WindowsPowerShell\v1.0\powershell.exe"
            #$thisuserupn = (get-aduser -server $global:targetserver ($Env:USERNAME)).userprincipalname
            $Opt = '-nologo -noninteractive -noprofile -ExecutionPolicy BYPASS -file "'+$PSScriptRoot+'\get-datawarehouse-cache.ps1" -noui'
            if (![string]::IsNullOrEmpty($subtenant)){$Opt=$Opt+' -subtenant "'+$subtenant+'"'}
            if ($queryo365 -eq $true){$Opt = "$Opt -queryo365"}
            if ($querymwp -eq $true){$Opt = "$Opt -querymwp"}
            $Action = New-ScheduledTaskAction -Execute $Prog -Argument $Opt  -WorkingDirectory $PSScriptRoot
            $Trigger = New-ScheduledTaskTrigger -Daily -DaysInterval 1 -At "01:00"
            #$Trigger.Repetition = $(New-ScheduledTaskTrigger -Once -At "02:00" -RepetitionDuration "22:00" -RepetitionInterval "00:10").Repetition
            $Settings = New-ScheduledTaskSettingsSet -DontStopOnIdleEnd -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 1 -StartWhenAvailable
            $Settings.ExecutionTimeLimit = "PT10M"
            $Task=Register-ScheduledTask -Action $Action -Trigger $Trigger -Settings $Settings -TaskName $ScheduledJobName -Description "Periodically sends updated data to the reporting datawarehouse via WebAPI" -User $Username -Password $Password -RunLevel Highest
            if ($querymwp -ne $true){
            $task.triggers.Repetition.Duration ="PT22H"
            $task.triggers.Repetition.Interval ="PT12M"
            }#Don't make the task recurring if it is processing MWP data - this data is only updated once per day.
            $task | Set-ScheduledTask -User $Username -Password $Password

            $ScheduledJobName = "Blue Net Warehouse Agent Update"
            Get-ScheduledTask -TaskName $ScheduledJobName -ErrorAction SilentlyContinue -OutVariable task
            if (!$task) {
            $Opt = '-nologo -noninteractive -noprofile -ExecutionPolicy BYPASS -file "'+$PSScriptRoot+'\update-bncacheagent.ps1"'
            $Action = New-ScheduledTaskAction -Execute $Prog -Argument $Opt  -WorkingDirectory $PSScriptRoot
            $Trigger = New-ScheduledTaskTrigger -Daily -DaysInterval 1 -At "00:35"
            $Settings = New-ScheduledTaskSettingsSet -DontStopOnIdleEnd -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 2 -StartWhenAvailable
            $Settings.ExecutionTimeLimit = "PT5M"
            Register-ScheduledTask -Action $Action -Trigger $Trigger -Settings $Settings -TaskName $ScheduledJobName -Description "Checks the GitHub repo for updated versions of datawarehouse scripts" -User $Username -Password $Password -RunLevel Highest

            }
        }# Yes - operater wants us to schedule this task
            }# End if (task doesn't already exist)

        }#End Function
    
    Function initialize-adsi(){
    # Verify we can load the Active Directory module.  If not prompt to download and install
    $ErrorActionPreference = 'Stop'
        $m = Get-Module -List activedirectory
        if(!$m) {
        $message1="Unable to find the ActiveDirectory PowerShell module.  This is required for operation.  For help please visit: https://www.google.com/search?q=how+to+install+the+Active+Directory+powershell+module"
        $answer=$false
        if (!$noui){
        $answer=yesorno "Would you like the ActiveDirectory PowerShell module installed on this workstation?" "Missing AD Powershell Module"
        }
        if ($noui){$answer=$true}
        if ($answer -eq $true){
            AddRegPath "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Servicing"
            Ver-RegistryValue -RegPath "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Servicing" -Name "RepairContentServerSource" -DefValue 2 -RegValType "Dword"
            $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
            $osInfo.ProductType
            if ($osInfo.ProductType -ne 1){
            Install-WindowsFeature RSAT-AD-PowerShell
            Write-Host "If the installation was successful, please try running the script again.  You SHOULD NOT require a reboot."
            exit
            } # Windows Server detected - use the Install-WindowsFeature method to install the AD tools
            elseif ( $((Get-WMIObject win32_operatingsystem).name) -like 'Microsoft Windows 10*' ) {
                $Install = Get-WindowsCapability -Online | Where-Object {$_.Name -like "Rsat.ActiveDirectory*" -AND $_.State -eq "NotPresent" }
                    foreach ($Item in $Install) {
                        $RsatItem = $Item.Name
                        Write-Verbose -Verbose "Adding $RsatItem to Windows"
                        try {
                            Add-WindowsCapability -Online -Name $RsatItem
                            } # end try
                        catch [System.Exception]
                            {
                            Write-Verbose -Verbose "Failed to add $RsatItem to Windows"
                            Write-Warning -Message $_.Exception.Message
                            } # end catch
                    } # end foreach $Item
                
                #OLD METHOD:
               #$client = new-object System.Net.WebClient
               #$dwnloaddst = $env:temp+"\install-admodule.ps1"
               #$client.DownloadFile("https://gallery.technet.microsoft.com/Install-the-Active-fd32e541/file/149000/1/Install-ADModule.p-s-1.txt",$dwnloaddst)
               #if (Test-Path $dwnloaddst) {
               #Write-Host "Installing ADModule...`n"
               #Invoke-Expression "& `"$dwnloaddst`" "
               #Write-Host "If the installation was successful, please try running the script again.  You SHOULD NOT require a reboot."
               #exit
               #} else {write-host "Download failed... You must install the ActiveDirectory PowerShell module for this agent to run properly.";
        } # Windows 10 detected
            } # User answered "yes, please install"
            if ($answer -eq $false) {
            Write-Warning $message1
            Sendto-eventlog -message $message1 -entrytype "Warning"
            Unregister-PSVars
            exit
            }
        } # We couldn't find the AD module installed
        

        
        
         #If there are old domain controllers (or not running AD Web Services) you can skip them by adding their hostname to the 'skipdc' reg_sz value
            #$ErrorActionPreference= 'SilentlyContinue'
            $Path = "HKCU:\Software\BNCacheAgent"
            $dcskiplist=Ver-RegistryValue -RegPath $Path -Name "skipdc" -DefValue "Skipthisserver" -regvaltype "MultiString"
            Show-onscreen $("SkipList result: $dcskiplist") 2

            $dcskiplist = if ($dcskiplist -eq $false -or [string]::IsNullOrEmpty($dcskiplist)) { "Skipthisserver" } else { $dcskiplist}
            if (! $dcskiplist -eq 'Skipthisserver') {write-host "per registry config Skipping $dcskiplist"}
            $Env:ADPS_LoadDefaultDrive = 0 #This prevents an error if your default ADC doesn't support ADWS

            TRY{
                import-module activedirectory
            }
            CATCH{
                $message1="Unable to load the ActiveDirectory PowerShell module.  This is required for operation.  For help please visit: " + "https://blogs.technet.microsoft.com/ashleymcglone/2016/02/26/install-the-active-directory-powershell-module-on-windows-10/  or https://www.google.com/search?q=how+to+install+the+Active+Directory+powershell+module"
                Write-Warning $message1
                Sendto-eventlog -message $message1 -entrytype "Warning"
                return $false
            }
           
            Do {
                $serverlist=netdom query dc| ForEach-Object{
                    $thisdc=$_
                    if (![string]::IsNullOrEmpty($_) -and $_ -notmatch "command completed" -and $_ -notmatch "List of domain" -and $_.toLower() -notmatch $dcskiplist ) {
                        if (![string]::IsNullOrEmpty($global:targetserver)) {
                            return}
                    Show-onscreen $("`nAttempt to query domain controller:$_") 2
                    try{$tenantname = get-addomain -server $_ | select-object -ExpandProperty "name"
                    Show-onscreen $("`ntenantdomain:$tenantname") 1
                        }
                    catch{
                    write-host "Unable to reach domain controller $thisdc."
                    if (!$noui){
                    $answer=yesorno "Would you like to skip $thisdc from future domain controller requests?"
                    if ($answer -eq $true){
                        if ($dcskiplist -eq 'Skipthisserver') {$dcskiplist = $thisdc}
                        if ($dcskiplist -ne 'Skipthisserver' -and $dcskiplist -ne $thisdc ) {$dcskiplist = $($dcskiplist+' '+$thisdc)}
                        Set-ItemProperty -Path $Path -Name "skipdc" -Value $dcskiplist -Force
                        }#Yes - remove this DC
                    }#$noui switch is not enabled
                    }
                    if (![string]::IsNullOrEmpty($tenantname)) {
                        Show-onscreen $("`nDomain Controller:$_") 1
                        $global:targetserver=$($_)
                    }# endif tenantname not null
                    }# this DC is a non-skip DC
                    }
                    #write-host "now a break?"
                    $DCTRY++
                    
            }
            until (![string]::IsNullOrEmpty($global:targetserver) -or $DCTRY -ge $serverlist.count)
            if ([string]::IsNullOrEmpty($global:targetserver)){
                Write-Warning "Was unable to identify a domain controller to query.  Stopping script execution."
                exit
            }
            Show-onscreen $("The target Domain Controller is $global:targetserver") 1
        
        return $true
        }# End initialize-adsi function
    
    Function submit-cachedata($Cachedata,[string]$DSName){
        if ($whatif -eq $true) {
            Write-Host "What-if scenario enabled - we're not going to actually submit data to the cache"
            return
        }
        Show-onscreen $("The cache data looks like this `n [$Cachedata]") 2
    # Takes the resulting cachedata and submits it to the webAPI
        Show-onscreen $("Submitting Data for $DSName") 2
        if ([string]::IsNullOrEmpty($DSName)){$DSName='Not Provided'}
        #write-host "******************************* the cache data is: `n"$Cachedata
        $ErrorActionPreference = 'Stop'
        Try{
        $apibase=$apisubmit

        $ServicePoint = [System.Net.ServicePointManager]::FindServicePoint($apibase)
        Show-onscreen $([System.Net.ServicePointManager]::FindServicePoint($apibase) | Out-String) 2

        $apiurlparms="?TenantGUID="+$tenantguid+"&DataSourceName="+$DSName+"&NewTimeStamp="+$querytimestamp
        $apiurl=$apibase+$apiurlparms.replace('+','%2b')
        
        write-host "dsname is $DSName" -ForegroundColor yellow

        if ($DSName -notlike '*vmware*' -and $DSName -notlike '*ms-dns*'){
        #VMware data is CSV, so don't convert it to json like the rest of the datasources
        $thecontent = (@{"data" = $Cachedata} | ConvertTo-Json -Compress)
        }
        $ErrorActionPreference= 'SilentlyContinue'
        Try{
        $pjmb=[math]::Round(([System.Text.Encoding]::UTF8.GetByteCount($Cachedata))*0.00000095367432,2) 
        Show-onscreen $("Submitting $ic updates for $DSName ($([math]::Round($pjmb,2))MB)") 2
            }
        Catch{
            Write-Host "Sorry - couldn't calculate a size estimate"
        }
        
        if ($DSName -like '*vmware*' -or $DSName -like '*ms-dns*'){
            
            if ($Cachedata -like '*.xlsx*' -and [System.IO.File]::Exists($Cachedata)){
                #write-host "using new submit method with infile" -ForegroundColor Magenta
                $oldlocation = (get-location).path
                $thecontent=$Cachedata.split('\')[-1]
                $thetemppath=$Cachedata.replace($thecontent,'')
                set-location $thetemppath
                Invoke-WebRequest $apiurl -Method 'Post' -Infile $thecontent -Headers @{"x-api-key"=$APIKey;"content-type" = "binary"} -ErrorVariable RestError -ErrorAction SilentlyContinue -TimeoutSec 900    
                set-location $oldlocation    
                }
                            else{
            #write-host "using legacy submit method with infile" -ForegroundColor Magenta
            $thecontent = $Cachedata
            Invoke-RestMethod $apiurl -Method 'Post' -Headers @{"x-api-key"=$APIKey;"content-type" = "binary"} -Body $thecontent -ErrorVariable RestError -ErrorAction SilentlyContinue -TimeoutSec 900
                            }# NOT xlsx file
            }
            else {
        if ($Cachedata -eq "Zero") {
            $thecontent = '{"result":"zero results"}'
        }# End if Cachdata -eq 'Zero'
        Invoke-RestMethod $apiurl -Method 'Post' -Headers @{"x-api-key"=$APIKey;Accept="application/json";"content-type" = "binary"} -Body $thecontent -ErrorVariable RestError -ErrorAction SilentlyContinue -TimeoutSec 900
        #write-host "******************************* the body data is: `n"$thecontent
            }
            $ServicePoint.CloseConnectionGroup("")
            start-sleep -milliseconds 250
        }
        Catch{
            $ErrorMessage = $_.Exception.Message
            $FailedItem = $_.Exception.ItemName
            $httpresponse = $_.Exception.Response
            $HttpStatusCode = $RestError.ErrorRecord.Exception.Response.StatusCode.value__
            $HttpStatusDescription = $RestError.ErrorRecord.Exception.Response.StatusDescription
            write-host "Error Message $ErrorMessage `nFailed Item:$FailedItem `nhttp Response:$httpresponse`n"
            $result = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($result)
                $reader.BaseStream.Position = 0
                $reader.DiscardBufferedData()
                $responseBody = $reader.ReadToEnd();
            Write-Host "`nFailed to submit $m to $apiURL $ErrorMessage $FailedItem" -ForegroundColor Yellow
            Write-Host "HTTP Response Status Code: "$HttpStatusCode
            Write-Host "HTTP Response Status Description: "$HttpStatusDescription
            Write-Host "TenantName: "$TenantName
            Write-Host "Result: "$responseBody
            $ErrorMessage=$("Script:$global:srccmdline`nFunction:submit-cachedata`nURL:apiURL`nError:$ErrorMessage $FailedItem`nHTTP Response Status Code:$HttpStatusCode`nHTTP Response Status Description:$HttpStatusDescription`nResult:$responseBody")
            write-host "Submitting Error:"
            Submit-agenterror $MyInvocation.MyCommand $ErrorMessage $DSName
            #$apibase=$apierror
            #$apiurlparms="?TenantGUID="+$tenantguid+"&DataSourceName="+$DSName
            #$apiurl=$apibase+$apiurlparms.replace('+','%2b')
            #write-host "Submitting Error:"
            #$thecontent = (@{"message" = $ErrorMessage} | ConvertTo-Json -Compress)
            #Invoke-RestMethod $apiurl -Method 'Post' -Headers @{"x-api-key"=$APIKey;Accept="application/json";"content-type" = "binary"} -ErrorVariable RestError  -Body $thecontent -ErrorAction SilentlyContinue -TimeoutSec 900 
        }

           
    }

    Function get-webapi-query([string]$apiqueryurl){
        Try{
            #$ServicePoint = [System.Net.ServicePointManager]::FindServicePoint($apiqueryurl)
            Show-onscreen $([System.Net.ServicePointManager]::FindServicePoint($apiqueryurl) | Out-String) 2
            $apiheaders = @{Authorization = $global:basicAuthValue}
            $Response = Invoke-RestMethod -uri $apiqueryurl -Headers $apiheaders -ErrorVariable RestError
            #$Response.value |ForEach-Object {
                #Write-Host "`nObject "$_
            #}
            return $Response.value
            }
            
            Catch{
                $ErrorMessage = $_.Exception.Message
                $FailedItem = $_.Exception.ItemName
                $httpresponse = $_.Exception.Response
                $HttpStatusCode = $RestError.ErrorRecord.Exception.Response.StatusCode.value__
                $HttpStatusDescription = $RestError.ErrorRecord.Exception.Response.StatusDescription
                if ($ErrorMessage -eq 'Unable to connect to the remote server'){
                    Write-Host "`n"
                    Write-Warning "Unable to connect to the remote server $baseapiurl"
                    Write-Host "Please check DNS, firewall, and Internet connectivity to verify."
                    exit
                }# End 'unable to connect' error message
                write-host "Error Message $ErrorMessage `nFailed Item:$FailedItem `nhttp Response:$httpresponse`n"
                $result = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($result)
                    $reader.BaseStream.Position = 0
                    $reader.DiscardBufferedData()
                    $responseBody = $reader.ReadToEnd();
                Write-Host "`nFailed to submit $m to $apiURL $ErrorMessage $FailedItem" -ForegroundColor Yellow
                Write-Host "HTTP Response Status Code: "$HttpStatusCode
                Write-Host "HTTP Response Status Description: "$HttpStatusDescription
                Write-Host "TenantName: "$TenantName
                Write-Host "Result: "$responseBody
                $ErrorMessage=$("Script:$global:srccmdline`nFunction:get-webapi-query`nURL:apiURL`nError:$ErrorMessage $FailedItem`nHTTP Response Status Code:$HttpStatusCode`nHTTP Response Status Description:$HttpStatusDescription`nResult:$responseBody")
                $apibase=$apierror
                $apiurlparms="?TenantGUID="+$tenantguid+"&DataSourceName=NotApplicable"
                $apiurl=$apibase+$apiurlparms.replace('+','%2b')
                write-host "Submitting Error:"
                $thecontent = (@{"message" = $ErrorMessage} | ConvertTo-Json -Compress)
                Invoke-RestMethod $apiurl -Method 'Post' -Headers @{"x-api-key"=$APIKey;Accept="application/json";"content-type" = "binary"} -ErrorVariable RestError  -Body $thecontent -ErrorAction SilentlyContinue -TimeoutSec 900 
                return $false
            } #end Catch
    }# End Function get-webapi-query

    Function get-mwpcreds([boolean]$allowpwchange){
        Add-Type -AssemblyName Microsoft.VisualBasic
        $Path = "HKCU:\Software\BNCacheAgent\$subtenant\mwpodata"
        $Path=$path.replace('\\','\')
        AddRegPath $Path
        #$result = Get-Set-Credential "MWPodata" $Path "MWPodataUser" "MWPodataPW" $false "domain\mwpodatauser"
        Get-Set-Credential "MWPodata" $Path "MWPodataUser" "MWPodataPW" $false "domain\mwpodatauser"
        #$credUser = Ver-RegistryValue -RegPath $Path -Name "MWPodataUser"
        #$credPwd=Get-SecurePassword $Path "MWPodataPW"
        Ver-RegistryValue -RegPath $Path -Name "MWPodataUser"
        Get-SecurePassword $Path "MWPodataPW"
    }

    function get-o365admin([boolean]$allowpwchange){
    }#End Function (get-o365admin)

    Function get-addns([string]$objclass){
        $ErrorActionPreference = 'Stop'
    }
    
    Function get-o365-assets([string]$objclass){
        }

Function Get-ADSIUsers([string]$requpdate){
	WRITE-Host "****************************************************************GETTING NEW METHOD ADSIUSERS ****************************************************************"
    $CvtDate = (Get-Date $requpdate).ToFileTime()
    $adusers = @()
    $Path = "HKCU:\Software\BNCacheAgent\"
    if (![string]::IsNullOrEmpty($subtenant)){$Path=$($Path+$subtenant)}
    $adsiconfigitems=(Get-Item $Path |
    Select-Object -ExpandProperty property |
    ForEach-Object {
    New-Object psobject -Property @{"property"=$_;
    "Value" = (Get-ItemProperty -Path $Path -Name $_).$_}})
    $defsearchbase=($adsiconfigitems | where-object -Property property -like 'searchbase').value # Use this SearchBase value unless a more specific one is provided
    $matchstring=$("searchbase-"+$ADObjclass)#object specific searchbase will be 'searchbase-[objectclass]'.  You can provide multiple searchbases by using a REG_MULTI_SZ value
    $specificsearchbase=($adsiconfigitems | where-object -Property property -like $matchstring).value
    $mysearchbase=""
    if (![string]::IsNullOrEmpty($defsearchbase)) {$mysearchbase=$defsearchbase}#use default searchbase if it is defined
    if (![string]::IsNullOrEmpty($specificsearchbase)) {$mysearchbase=$specificsearchbase}# use an objectclass specific searchbase if it is defined
    $dcskiplist=Ver-RegistryValue -RegPath $Path -Name "skipdc" -DefValue "Skipthisserver" -regvaltype "MultiString"
    #$dcskiplist=(Get-ItemProperty -Path $Path -Name skipdc).skipdc
    netdom query dc|  where-object {![string]::IsNullOrEmpty($_) -and $_ -notmatch "command completed" -and $_ -notmatch "List of domain" -and ($_ -notin $dcskiplist)} | ForEach-Object {
        $_
    $dcname=$_
    $myfilter="(objectClass -eq 'User') "
    Try{
    if (![string]::IsNullOrEmpty($mysearchbase)){
        $arrsb=@($mysearchbase -split '\r?\n')# If the regvalue was multi-line we need to split it into multiple searchbase entries
        $adresults=($arrsb | ForEach-object {get-aduser -server $dcname -Searchbase $_ -Filter $myfilter -Properties * -ErrorAction SilentlyContinue | Select-Object * | Where-object {$_.Modified -ge $requpdate -or $_.lastlogon -ge $CvtDate }})
	
        ForEach ($sb in $arrsb){
        show-onscreen $("{get-aduser -server $dcname -Searchbase $sb -Filter $myfilter -Properties lastlogon,objectguid,name -ErrorAction SilentlyContinue | select lastlogon,objectguid,name | Where-object {_.lastlogondate -ge $requpdate}") 4
        }
        
        }#We have a custom searchbase
    else {
        #Show-onscreen $("AD Query: Get-ADObject -resultpagesize 50 -server $dcname -Filter $myfilter -Properties LastLogon,Modified -ErrorAction SilentlyContinue | Where-object {$_.lastlogondate -lt $requpdate}") 2
        $adresults = get-aduser -server $dcname -Filter $myfilter -Properties * -ErrorAction SilentlyContinue | Select-Object * | Where-object {$_.Modified -ge $requpdate -or $_.lastlogon -ge $CvtDate }
        }# No custom searchbase
		Show-onscreen $("We retrieved $($adresults.count) that matched the filter") 2
    }#End Try

    Catch{
        Write-Host "Sorry - we failed miserably"
        $ErrorMessage = $_.Exception.Message
        $FailedItem = $_.Exception.ItemName
        Write-Host "message: $ErrorMessage  item:$FailedItem"
        if ($ErrorMessage -like "*object not found*"){
            Write-Warning "Possibly a permissions issue with the user account querying Active Directory?"
             $ErrorMessage=$("Script:$global:srccmdline`nFunction:get-o365admin`nURL:apiURL`nError:$($_.Exception.Message) $($_.Exception.ItemName)")
            $apiurlparms="?TenantGUID="+$tenantguid+"&DataSourceName=NotApplicable"
            $apiurl=$apibase+$apiurlparms.replace('+','%2b')
            write-host "Submitting Error:"
            $thecontent = (@{"message" = $ErrorMessage} | ConvertTo-Json -Compress)
            Invoke-RestMethod $apiurl -Method 'Post' -Headers @{"x-api-key"=$APIKey;Accept="application/json";"content-type" = "binary"} -ErrorVariable RestError  -Body $thecontent -ErrorAction SilentlyContinue -TimeoutSec 900 
        }
        #exit
    } # End Catch     
    
    write-host "we got $($adresults.count) users"
    $adresults | foreach-object {
        $uguid=$_.ObjectGUID
        $lstlogon=$_.LastLogon
        $myuser=$adusers | Where-Object {$_.ObjectGUID -eq $uguid}
    
        if ($myuser.ObjectGUID -eq $uguid) {
             if ($null -eq $lstlogon) {[int64]$d1=0} else {[int64]$d1=$lstlogon}
            if ($null -eq $myuser.LastLogon) {[int64]$d2=0} else {[int64]$d2=$myuser.LastLogon}
      			
        if ((get-date $d1) -gt (get-date $d2) ) {
        #write-host "Update the logon time for $($_.Name) from $([datetime]::FromFileTime($myuser.LastLogon)) to $([datetime]::FromFileTime($_.Lastlogon)) because $dcname has a newer time."
        $myuser.LastLogon=$lstLogon
        }# End LastLogon is newer - let's update!
        }# We found the user in the object list - let's compare LastLogon
    
    If (!($myuser)) {
    Show-onscreen $("Collecting logon information for $($_.name)") 4
   $adusers  += $_

<#   $adusers  += [pscustomobject]@{
        Name=$_.Name
        userPrincipalname=$_.userPrincipalname
		ObjectGUID=$_.ObjectGUID
        LastLogon=$_.LastLogondate
		physicalDeliveryOfficeName=$_.physicalDeliveryOfficeName
        LastLogoncvt=[datetime]::FromFileTime($_.Lastlogon)
        dc=$dcname
    }#>
    
    }# End if user missing from array
    }# Next $users object

    }# Next Domain Controller
	
	#Add Privilege property to each user based on group membership
    $adusers | ForEach-Object {
	
        If($_.MemberOf -like "*Domain Admin*" -or $_.MemberOf -like "*Administrators*" -or $_.MemberOf -like "*Enterprise Admin*" -or $_.MemberOf -like "*Schema Admin*")
        {
        #$accountType = "High Privilege Account"
        $_ | Add-Member -Name "accountprivilege" -Type NoteProperty -Value "High Privilege Account" -Force
        }
        elseIf($_.MemberOf -like "*server operator*" -or $_.MemberOf -like "*backup operator*" -or $_.MemberOf -like "*admin*")
        {
        $_ | Add-Member -Name "accountprivilege" -Type NoteProperty -Value "Limited Privilege Account"  -Force
        #$accountType = "Limited Privilege Account"
        }
        elseIf($_.Description -like "Built-in*")
        {
        $_ | Add-Member -Name "accountprivilege" -Type NoteProperty -Value "System Account"  -Force
        #$accountType = "System Account"
        }
        else
        {
        $_ | Add-Member -Name "accountprivilege" -Type NoteProperty -Value "Non privileged account"  -Force
        #$accountType = "Non privileged account"
        }
        $_ | Add-Member -Name "lastlogindelve" -Type NoteProperty -Value ([datetime]::FromFileTime($_.lastlogon))  -Force
		$_ | Add-Member -Name "physicalDeliveryOfficeName" -Type NoteProperty -Value $($_.physicalDeliveryOfficeName)  -Force
		

    }# End ForEach-Object
		
    Show-onscreen $("We received $($adusers.count) User LastLogon updates to submit to the API.") 1
    $ic = [int]($adusers | measure-object).count
    if ($ic -eq 0) {
    $adoutput = "Zero"
    }
    if ($ic -ge 1) {
    $allProperties =  $adusers | ForEach-Object{ $_.psobject.properties | select-object Name } | select-object -expand Name -Unique | sort-object
    $adoutput = $adusers | select-object $allProperties 
    }#We had at least 1 result in $ic
    write-host "cache data is "$adoutput
    submit-cachedata $adoutput "ADSI-user"
} # End Function Get-ADSIUser

Function get-filteredadobject([string]$ADObjclass,[string]$requpdate){
    $ErrorActionPreference = 'stop'
    $DefDate = 	[datetime]"4/25/1980 10:05:50 PM"
    #$global:querytimestamp=[DateTime]::UtcNow | get-date -Format "yyyy-MM-ddTHH:mm:ss" (never used)
    #$dtenow = (Get-Date).tostring()
    if ($requpdate -eq [DBNull]::Value -or [string]::IsNullOrEmpty($requpdate)) {
        $requpdate = [datetime]$DefDate
    }
        #Pull all the registry settings into a hashtable
        
        $Path = "HKCU:\Software\BNCacheAgent\"
        if (![string]::IsNullOrEmpty($subtenant)){$Path=$($Path+$subtenant)}
        $adsiconfigitems=(Get-Item $Path |
        Select-Object -ExpandProperty property |
        ForEach-Object {
        New-Object psobject -Property @{"property"=$_;
        "Value" = (Get-ItemProperty -Path $Path -Name $_).$_}})
    
    #To access a value from $adsiconfigitems
    # $myvalue=($adsiconfigitems | where-object -Property property -like 'Searchbase-objectclass').value
    $defsearchbase=($adsiconfigitems | where-object -Property property -like 'searchbase').value # Use this SearchBase value unless a more specific one is provided
    $matchstring=$("searchbase-"+$ADObjclass)#object specific searchbase will be 'searchbase-[objectclass]'.  You can provide multiple searchbases by using a REG_MULTI_SZ value
    $specificsearchbase=($adsiconfigitems | where-object -Property property -like $matchstring).value
    $mysearchbase=""
    if (![string]::IsNullOrEmpty($defsearchbase)) {$mysearchbase=$defsearchbase}#use default searchbase if it is defined
    if (![string]::IsNullOrEmpty($specificsearchbase)) {$mysearchbase=$specificsearchbase}# use an objectclass specific searchbase if it is defined
    $tenantlastupdate = [datetime]$requpdate
    Show-onscreen $("`nAPI Requesting $ADObjclass data newer than [$tenantlastupdate]") 2
    $myfilter="(objectClass -eq '$ADObjclass') -and (modified -gt '$tenantlastupdate')"
        if ($ADObjclass -eq 'deleted') {
            $myfilter="(isdeleted -eq 'TRUE') -and (name -ne 'Deleted Objects')"
        }
    Try{
    if (![string]::IsNullOrEmpty($mysearchbase)){
        Show-onscreen $("Got searchbase results:$mysearchbase`n Now process them one-at-a-time:") 3
        $arrsb=@($mysearchbase -split '\r?\n')# If the regvalue was multi-line we need to split it into multiple searchbase entries
        #$adresults=($arrsb | ForEach {Get-ADObject -resultpagesize 50 -server $targetserver -Searchbase $_ -Filter $myfilter -Properties * -ErrorAction SilentlyContinue})
        Show-onscreen $("We got "+$arrsb.count+" searchbase results`n") 4
        Show-onscreen $($arrsb | Format-List) 4
        $adresults=($arrsb | ForEach-object {
        Show-onscreen $("`nGet-ADObject -server $targetserver -Searchbase $_ -Filter $myfilter -includeDeletedObjects -Properties * -ErrorAction SilentlyContinue") 4
        if ([adsi]::Exists("LDAP://"+$_)){
        Get-ADObject -server $targetserver -Searchbase $_ -Filter $myfilter -Properties * -ErrorAction SilentlyContinue
        }
        if (![adsi]::Exists("LDAP://"+$_)){
        Submit-agenterror $($MyInvocation.MyCommand) "Unable to query ADSI for searchbase:$_ " $ADObjclass  
        }
        
        })   
                
        #$arrsb | ForEach-object {Show-onscreen $("Get-ADObject -server $targetserver -Searchbase $_ -Filter $myfilter -Properties * -ErrorAction SilentlyContinue") 4}
        }#We have a custom searchbase
    else {
        Show-onscreen $("AD Query: Get-ADObject -resultpagesize 50 -server $targetserver -Filter $myfilter -includeDeletedObjects -Properties *") 2
        #$adresults = Get-ADObject -resultpagesize 50 -server $targetserver -Filter $myfilter -Properties *
        $adresults = Get-ADObject -server $targetserver -Filter $myfilter -includeDeletedObjects -Properties *
        }# No custom searchbase
    }#End Try

    Catch{
        $ErrorMessage = $_.Exception.Message
        $FailedItem = $_.Exception.ItemName
        Show-onscreen ("Error querying $ADObjclass via ADSI: $ErrorMessage  item:$FailedItem") 2
        if ($ErrorMessage -like "*object not found*"){
            Write-Warning "Possibly a permissions issue with the user account querying Active Directory?"
        }
        Submit-agenterror $MyInvocation.MyCommand $ErrorMessage $ADObjclass
    } # End Catch

    $ic = [int]($adresults | measure-object).count
    if ($ic -eq 0) {
    $adoutput = "Zero"
    }
    if ($ic -ge 1) {
    $allProperties =  $adresults | ForEach-Object{ $_.psobject.properties | select-object Name } | select-object -expand Name -Unique | sort-object
    $adoutput = $adresults | select-object $allProperties}#We had at least 1 result in $ic
    Show-onscreen $("We received $ic $ADObjclass updates to submit to the API.") 1
    submit-cachedata $adoutput $($_.SourceName)
    return
}# End Function get-filteredadobject

Function Unregister-PSVars {
    $ErrorActionPreference= 'SilentlyContinue'
    Show-onscreen $("`nCleaning up after myself...") 2
    Get-PSSession | Remove-PSSession | Out-Null
    Remove-Variable -name querymwp | Out-Null
    Remove-Variable -name queryo365 | Out-Null
    Remove-Variable -name querytimestamp | Out-Null
    Remove-Variable -name apikey | Out-Null
    Remove-Variable -name tenantguid | Out-Null
    Remove-Variable -name params | Out-Null
    Remove-Variable -name targetserver | Out-Null
    Remove-Variable -name srccmdline | Out-Null
    Remove-Variable -name RVToolsPathExe | Out-Null
    Remove-Variable -name RVToolsVersion | Out-Null
    Remove-Variable -name vmwarereq | Out-Null
    Remove-Variable -name R2 | Out-Null
    Remove-Variable -name Response | Out-Null
    Remove-Variable -name Error | Out-Null
    } #End Function Unregister-PSVars

# *********************************************The main script begins here ************************************************
$Path = "HKCU:\Software\BNCacheAgent\$subtenant\"
    $Path=$Path.replace('\\','\')

$srcskiplist=Ver-RegistryValue -RegPath $Path -Name "skipsource" -regvaltype "MultiString"
Show-onscreen $($srcskiplist | ForEach-Object {
    Write-Host "Ignoring requests for datasources that include: $_"}
    ) 2
if (!$srcskiplist) {$srcskiplist="dontskipanything"}


    Try{
    Show-onscreen "Retrieve TenantGUID for $tenantdomain" 2
    $tenantguid = GetKey $($Path+$tenantdomain) $("TenantGUID") $("Enter Unique GUID for $tenantdomain in the password field:")
    }

    Catch
    {
        $ErrorMessage = $_.Exception.Message
        $FailedItem = $_.Exception.ItemName
        Write-Host "Failed to retrieve tenant GUID from registry The error message was '$ErrorMessage'  It is likely that you are not running this script as the original user who saved the secure tenant GUID."
        Unregister-PSVars
        Break
        exit
    }

    Try
    {
        $Path = "HKCU:\Software\BNCacheAgent\"
        $APIKey = GetKey $($Path) $("APIKey") $("Enter global APIKey in the password field:")
    }

    Catch
    {
        $ErrorMessage = $_.Exception.Message
        $FailedItem = $_.Exception.ItemName
        Write-Host "Failed to retrieve APIKey from registry The error message was '$ErrorMessage'  It is likely that you are not running this script as the original user who saved the APIKey value."
        Unregister-PSVars
        Break
        exit
    }  

Try{

# Attempt to query the API to find out what data they would like us to retrieve
$Howsoonisnow=[DateTime]::UtcNow | get-date -Format "yyyy-MM-ddTHH:mm:ss"
Show-onscreen "UTC is $Howsoonisnow" 2

#$ServicePoint = [System.Net.ServicePointManager]::FindServicePoint($apiurl)
Show-onscreen $([System.Net.ServicePointManager]::FindServicePoint($apigetreq) | Out-String) 2
$params = @{"TenantGUID"=$tenantguid; "ClientAgentUTCDateTime" = $Howsoonisnow}
$Response = Invoke-RestMethod -uri $apigetreq -Body $params -Method GET -Headers @{"x-api-key"=$APIKey;Accept="application/json"} -ErrorVariable RestError -ErrorAction SilentlyContinue
Show-onscreen $((($Response | Format-List) | Out-String)) 2
#$Response | fl
}

Catch{
    $ErrorMessage = $_.Exception.Message
    $FailedItem = $_.Exception.ItemName
    $httpresponse = $_.Exception.Response
    $HttpStatusCode = $RestError.ErrorRecord.Exception.Response.StatusCode.value__
    $HttpStatusDescription = $RestError.ErrorRecord.Exception.Response.StatusDescription
    if ($ErrorMessage -eq 'Unable to connect to the remote server'){
        Write-Host "`n"
        Write-Warning "Unable to connect to the remote server $baseapiurl"
        Write-Host "Please check DNS, firewall, and Internet connectivity to verify."
        exit
    }
    write-host "Error Message $ErrorMessage `nFailed Item:$FailedItem `nhttp Response:$httpresponse`n"
    $result = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($result)
        $reader.BaseStream.Position = 0
        $reader.DiscardBufferedData()
        $responseBody = $reader.ReadToEnd();
    Write-Host "`nFailed to submit $m to $apiURL $ErrorMessage $FailedItem" -ForegroundColor Yellow
    Write-Host "HTTP Response Status Code: "$HttpStatusCode
    Write-Host "HTTP Response Status Description: "$HttpStatusDescription
    Write-Host "TenantName: "$TenantName
    Write-Host "Result: "$responseBody
    EXIT
}

$R2 = $Response | Convertfrom-Json
($R2.DataRequests | Measure-Object).count
if (($R2.DataRequests | Measure-Object).count -eq 0){
    Write-Host "Client identified successfully - no data requests at this time.  If this is your first run, please be sure the client's reporting setup has been completed."
    Write-Host "Req: "($R2.DataRequests | Measure-Object).count
    exit
    }


    $o365req=($r2.DataRequests | where-object -Property SourceName -like 'O365*')
    if (![string]::IsNullOrEmpty($o365req) -and $queryo365 -eq $true -and -not @($srcskiplist| Where-Object {$_ -like 'o365'}).Count) {
        Try{
            write-host "Initializing office 365"
            $o365initialized=(get-o365admin $false)
            write-host "got o365admin  and the results are $o365initialized"
        }
        Catch{
            write-host "Sorry - O365 init epic failure!"
        }
        
    }# end initializing O365

    $vmwarereq=($r2.DataRequests | where-object -Property SourceName -like '*vmware*')
    if (![string]::IsNullOrEmpty($vmwarereq) -and -not @($srcskiplist| Where-Object {$_ -like 'vmware'}).Count) {
    
    Show-onscreen $("Initializing VMware module.") 1
            # Ensure we are able to load the get-vmware-data.ps1 include.
                $ErrorActionPreference = 'stop'
                Show-onscreen $("loading the vmware include file...$PSScriptRoot\get-vmware-data.ps1") 2
                Try{. "$PSScriptRoot\get-vmware-data.ps1"}
                Catch{
                    Write-Warning "I wasn't able to load the get-vmware-data.ps1 include script (which should live in the same directory as $global:srccmdline). `nWe are going to bail now, sorry 'bout that!"
                    Write-Host "Try running them manually, and see what error message is causing this to puke: $PSScriptRoot\get-vmware-data.ps1"
                    Unregister-PSVars
                    BREAK
                    }# End Catch
    
    $ErrorActionPreference = 'Stop'
    $VMwareinitialized=(get-vcentersettings)
    Show-onscreen $("VMware initialization result: $VMwareinitialized") 2
    }

    $adsireq=($r2.DataRequests | Where-Object -Property SourceName -like 'ADSI*')
    if (![string]::IsNullOrEmpty($adsireq) -and -not @($srcskiplist| Where-Object {$_ -like 'adsi'}).Count) {
        $ErrorActionPreference = 'Stop'
        Try{
            Show-onscreen $("Initializing ActiveDirectory Module") 1
            $adinitialized=(initialize-adsi)    
        }
        Catch{
            write-host "Sorry - ActiveDirectory initialization was an epic failure!"
        }
        Show-onscreen $("initialize-adsi result:$adinitialized") 2
    }# end initializing AD Module
    
$dr = 0
Show-onscreen $("Processing "+$(($R2.DataRequests | Measure-Object).count)+"data object requests.") 1
#if (($R2.DataRequests | Measure-Object).count -ge 1)
$R2.DataRequests | ForEach-Object{
$dr++
Show-onscreen $("Processing $dr of"+$(($R2.DataRequests | Measure-Object).count)+" data object requests.") 2

#Show-onscreen $("Should I skip? "+$R2.DataRequests+":"+$(-not @($srcskiplist| where {$R2.DataRequests -like $_}).Count)) 2

$global:querytimestamp=[DateTime]::UtcNow | get-date -Format "yyyy-MM-ddTHH:mm:ss"
#$DueDate=$_.NextUpdateDue
$DueDate=$_.NextUpdateDueUTC
$ModDate=$_.LastUpdateUTC
$MaxAge=$_.MaxAgeMinutes
#$HasModified=$_.HasModifiedDate #Never used
#$Delegated=$_.O365DelegatedAdmin #Never used
$SourceReqUpdate = $false
$Datasource=$_.SourceName

if ( @($srcskiplist| Where-Object {$Datasource -like $($_+"*")}).Count -ge 1) {
    Show-onscreen $($Datasource+" Is being ignored because skipsource told me to ignore.") 2
    return 
}
if ($querytimestamp -ge $DueDate) {
   $SourceReqUpdate=$true
   Show-onscreen $($_.SourceName+"Next Update requested at/after [$DueDatee] with a MaxAge of $MaxAge and will be updated.") 2
}
if (!$SourceReqUpdate){
    Show-onscreen $($_.SourceName+"Next Update requested at/after [$DueDate] with a MaxAge of $MaxAge and is not in need of a query") 2
    return
}
    if ($_.SourceName -like "*ADSI*"){
        if ($adinitialized -eq $false){
            show-onscreen $("Warning: API has requested Active Directory data, but I could not initialize the ActiveDirectory Module.") 2
            Submit-agenterror $MyInvocation.MyCommand "Warning: API has requested Active Directory data, but I could not initialize the ActiveDirectory Module." $_.SourceName
            return
            }
    $Source=$_.SourceName.replace('ADSI-','')
    Show-onscreen $("Request for Active Directory $Source data from $ModDate or later.") 3
    $ErrorActionPreference = 'Stop'
    if (!($Source -like "*lastlogon*" -or $Source -like "*user*" )){
    $intresult=(get-filteredadobject $($Source) $($ModDate))
    }
    if ($Source -like "*lastlogon*"){
        #$intresult=(get-lastlogon $($ModDate)) Just skip it!
        }
	if ($Source -like "*user*"){
		Show-onscreen $($_.SourceName+"Next Update requested at/after [$DueDate] with a MaxAge of $MaxAge.  Get any data after [$Moddate]") 2
        $intresult=(Get-ADSIUsers $($ModDate))
        }
    Show-onscreen $("$intresult items returned") 2
    }# end if (ADSI source request)
elseif ($_.SourceName -like "*vmware*"){
    $Source=($_.SourceName).ToLower()
    $Source=$Source.replace('vmware ','')
    if ($VMwareinitialized -eq $false){
        show-onscreen $("Warning:API has requested VMware data, but I could not initialize the VMware data requester.") 2
        Submit-agenterror $MyInvocation.MyCommand "Warning:API has requested VMware data, but I could not initialize the VMware data requester." $_.SourceName
        #exit
        }
    if ($VMwareinitialized -eq $true){
        Show-onscreen $("Requesting VMware assets ("+$($_.SourceName)+") for $Source") 1
        $global:querytimestamp=[DateTime]::UtcNow | get-date -Format "yyyy-MM-ddTHH:mm:ss"
        $vmresult=get-vmware-assets $Source
        #write-host "The resulting VM data request is..."
        #Write-host "vmr: $vmresult"
        if ($vmresult -ne $false){
            #Now take the resulting export file and submit to the cache ingester:
            Get-ChildItem $vmresult -Filter *.csv | Foreach-Object { 
                #$Objclass = $($_.Name).replace('RVTools_tab','').replace('.csv','')
                #Write-Host "Let's send VM Data ($Source) from $Objclass to the API Cache ingester!"
                $csvfilename = "$vmresult\"+$_.Name
                #$content = (Import-Csv -Path $csvfilename)
                $content = [IO.File]::ReadAllText($csvfilename);
                #$ic=(Import-Csv $csvfilename | Measure-Object).count # Never Used
                $srcname="Vmware "+$Source
                submit-cachedata $content $srcname
                #write-host "and here's the data we will submit `n $content"
                Remove-Item -path $csvfilename
            }# end Foreach-Object
            Get-ChildItem $vmresult -Filter *.xlsx | Foreach-Object { 
                $xlsxfilename = "$vmresult\"+$_.Name
                #$bytes = [System.IO.File]::ReadAllBytes($xlsxfilename)
                $srcname="Vmware "+$Source
                submit-cachedata $xlsxfilename $srcname
                #Remove-Item -path $xlsxfilename
                }# end Foreach-Object

            #Remove-Item -path $vmresult -Recurse
        } # End if we received a valid VM data export file!
    } # end if VMwareinistialized
} # End elseif $_.SourceName -like "*vmware*"
elseif ($_.SourceName -like "o365*"){

if ($queryo365 -ne $true){
    Write-Host "Office365 processing was not enabled.  to enable, add -queryo365 $true to the commandline when executing the script."
    return
}

if ($o365initialized -eq $false){
    Write-Warning "API has requested O365 data, but I could not initialize the MsolService."
    exit
    }
    $global:querytimestamp=[DateTime]::UtcNow | get-date -Format "yyyy-MM-ddTHH:mm:ss"
    $o365result=get-o365-assets $_.Sourcename
    submit-cachedata $o365result $_.SourceName

}# $_.SourceName -like "o365*"

elseif ($_.SourceName -like "mwp*"){
if ($querymwp -eq $true){
    Write-Host "MWP Data processing is enabled."
    if ([string]::IsNullOrEmpty($encodedmwpCreds)){
        $Path = "HKCU:\Software\BNCacheAgent\$subtenant\mwpodata"
        $Path=$path.replace('\\','\')
        get-mwpcreds
        $credUser = Ver-RegistryValue -RegPath $Path -Name "MWPodataUser"
        $credPwd=Get-SecurePassword $Path "MWPodataPW"
        $pair = "$($credUser):$($credPwd)"
        $encodedmwpCreds = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
        $global:basicAuthValue = "Basic $encodedmwpCreds" 
        }
    $mwpresult=get-mwp-assets $_.Sourcename
    submit-cachedata $mwpresult $_.SourceName
    } # End $querymwp is $true
    }# End $_.SourceName -like "mwp*"

elseif ($_.SourceName -like "ms-dns"){

  $scriptpath = "$PSScriptRoot\get-dns.ps1"
  if ($noui) {$dnsresult = . $scriptpath -api -noui}
  if (!$noui) {$dnsresult = . $scriptpath -api}
  
  write-host "The DNS result is $dnsresult"
  
    if (!([string]::IsNullOrEmpty($dnsresult).fullname)){
        #Now take the resulting export files and submit to the cache ingester:
        Get-ChildItem $dnsresult.fullname -Filter *.cypher | Foreach-Object { 
            #Write-Host "Let's send MS-DNS Data to the API Cache ingester!"
            $cqlfilename = ($dnsresult).fullname+"\"+$_.Name
            $content = [IO.File]::ReadAllText($cqlfilename);
            submit-cachedata $content "ms-dns"
            start-sleep -milliseconds 333
            Remove-Item -path $cqlfilename
        }# end Foreach-Object
        Remove-Item -path ($dnsresult).fullname -Recurse
    }#dnsresult was not emptry
    }# end SourceName -like "ms-dns"

    else {
    write-host "Some other data request... "$_.SourceName" ... and I have no idea what to do with it!"
    return
}
}# Next $R2.DataRequests object
Show-onscreen $("Processing "+$(($R2.DataRequests | Measure-Object).count)+" requests completed.") 1

if ($noui -ne $true){
    # Check to see if the job is scheduled
    Set-CacheSyncJob
}

# Cleanup the variables used in this script
Unregister-PSVars








