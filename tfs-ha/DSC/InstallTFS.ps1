configuration TFSInstallDsc
{
    param
    (
        [Parameter(Mandatory)]
        [string]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds,

        [Parameter(Mandatory)]
        [String]$SqlServerInstance,

        [Parameter(Mandatory)]
        [String]$primaryInstance,

        [Parameter(Mandatory=$true)]
        [String]$GlobalSiteIP,

        [Parameter(Mandatory=$false)]
        [String]$GlobalSiteName = "TFS",

        [Parameter(Mandatory=$false)]
        [String]$DnsServer = "DC1",

        [Parameter(Mandatory=$false)]
        [String]$ProbePort = '59999',

        [Parameter(Mandatory=$false)]
        [String]$SslThumbprint = "generate",

        [Parameter(Mandatory=$false)]
        [ValidateSet("TFS2018", "TFS2017Update3","TFS2017Update2")]
        [String]$TFSVersion = "TFS2018"
    )

    [System.Management.Automation.PSCredential ]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
    
    Import-DscResource -ModuleName  xStorage, xPendingReboot, xDnsServer, xWebAdministration, xNetworking, 'PSDesiredStateConfiguration'

    <#
        Download links for TFS:

        2017Update2: https://go.microsoft.com/fwlink/?LinkId=850949
        2017Update3: https://go.microsoft.com/fwlink/?LinkId=857134
        2018: https://go.microsoft.com/fwlink/?LinkId=856344
    #>

    $TFSDownloadLinks = @{
        "TFS2018" = "https://go.microsoft.com/fwlink/?LinkId=856344"
        "TFS2017Update2" = "https://go.microsoft.com/fwlink/?LinkId=850949"
        "TFS2017Update3" = "https://go.microsoft.com/fwlink/?LinkId=857134"
    }
  
    $currentDownloadLink = $TFSDownloadLinks[$TFSVersion]
    $installerDownload = $env:TEMP + "\tfs_installer.exe"
    $isTFS2017 = $false
    $hostName = $env:COMPUTERNAME

    $isPrimaryInstance = $primaryInstance -eq $env:COMPUTERNAME

    if ($TFSVersion.Substring(0,7) -eq "TFS2017") {
        $isTFS2017 = $true
    }
	
    $TfsConfigExe = "C:\Program Files\Microsoft Team Foundation Server 2018\Tools\TfsConfig.exe"

    if ($isTFS2017) {
        $TfsConfigExe = "C:\Program Files\Microsoft Team Foundation Server 15.0\Tools\TfsConfig.exe"
    }
    
    Node localhost
    {   
		
        WindowsFeature ADPS
        {
            Name = "RSAT-AD-PowerShell"
            Ensure = "Present"
        }


        WindowsFeature DNSServer
        {
            Name = "RSAT-DNS-Server"
            Ensure = "Present"
            DependsOn = "[WindowsFeature]ADPS"
        }

        WindowsFeature IISPresent
        {
            Ensure = "Present" 
            Name = "Web-Server"  
        }

        xWebsite DefaultSite
        {
            Ensure          = 'Present'
            Name            = 'Default Web Site'
            State           = 'Stopped'
            PhysicalPath    = 'C:\inetpub\wwwroot'
            DependsOn       = '[WindowsFeature]IISPresent'
        }
        
		xWaitforDisk Disk2
        {
                DiskId = 2
                RetryIntervalSec =$RetryIntervalSec
                RetryCount = $RetryCount
                DependsOn = "[WindowsFeature]DNSServer"
        }

        xDisk ADDataDisk
        {
            DiskId = 2
            DriveLetter = "F"
            DependsOn = "[xWaitForDisk]Disk2"
        }

        Script DownloadTFS
        {
            GetScript = { 
                return @{ 'Result' = $true }
            }
            SetScript = {
                Write-Host "Downloading TFS: " + $using:currentDownloadLink
                Invoke-WebRequest -Uri $using:currentDownloadLink -OutFile $using:installerDownload
            }
            TestScript = {
                Test-Path $using:installerDownload
            }
			DependsOn = "[xDisk]ADDataDisk"
        }
        
        Script InstallTFS
        {
            GetScript = { 
                return @{ 'Result' = $true }
            }
            SetScript = {
                Write-Verbose "Install TFS..."                
                
                $cmd = $using:installerDownload + " /full /quiet /Log $env:TEMP\tfs_install_log.txt"
                Write-Verbose "Command to run: $cmd"
                Invoke-Expression $cmd | Write-Verbose


                #Sleep for 10 seconds to make sure installer is going
                Start-Sleep -s 10

                #The tfs installer will per default run in the background. We will wait for it. 
                Wait-Process -Name "tfs_installer"
            }
            TestScript = {
                Test-Path $using:TfsConfigExe
            }
            DependsOn = "[Script]DownloadTFS"
        }
 
 
        xPendingReboot PostInstallReboot {
            Name = "Check for a pending reboot before changing anything"
            DependsOn = "[Script]InstallTFS"
        }
 
        LocalConfigurationManager{
            RebootNodeIfNeeded = $True
        }
                
        Script ConfigureTFS
        {
            GetScript = {
                return @{ 'Result' = $true }                
            }
            SetScript = {
                $siteBindings = "https:*:443:" + $using:hostName + "." + $using:DomainName + ":My:" + $using:SslThumbprint

                if ($using:hostName -ne $using:GlobalSiteName) {
                    $siteBindings += ",https:*:443:" + $using:GlobalSiteName + "." + $using:DomainName + ":My:" + $using:SslThumbprint
                }

                $siteBindings += ",http:*:80:"

                $publicUrl = "http://$using:hostName"

                $cmd = ""
                if ($using:isPrimaryInstance) {                
                    $cmd = "& '$using:TfsConfigExe' unattend /configure /continue /type:NewServerAdvanced  /inputs:WebSiteVDirName=';'PublicUrl=$publicUrl';'SqlInstance=$using:SqlServerInstance';'SiteBindings='$siteBindings'"
                } else {
                    $cmd = "& '$using:TfsConfigExe' unattend /configure /continue /type:ApplicationTierOnlyAdvanced  /inputs:WebSiteVDirName=';'PublicUrl=$publicUrl';'SqlInstance=$using:SqlServerInstance';'SiteBindings='$siteBindings'"
                }

                Write-Verbose "$cmd"
                Invoke-Expression $cmd | Write-Verbose

                $publicUrl = "https://$using:GlobalSiteName" + "." + $using:DomainName
                $cmd = "& '$using:TfsConfigExe' settings /publicUrl:$publicUrl"
                Write-Verbose "$cmd"
                Invoke-Expression $cmd | Write-Verbose

            }
            TestScript = {
                $sites = Get-WebBinding | Where-Object {$_.bindingInformation -like "*$using:GlobalSiteName*" }
                -not [String]::IsNullOrEmpty($sites)
            }
            DependsOn = "[xPendingReboot]PostInstallReboot","[xWebsite]DefaultSite"
            PsDscRunAsCredential = $DomainCreds
        }

        xDnsRecord GlobalDNS
        {
            Name = $GlobalSiteName
            Target = $GlobalSiteIP
            Type = "ARecord"
            Zone = $DomainName
            DependsOn = "[Script]ConfigureTFS"
            DnsServer = $DnsServer
            PsDscRunAsCredential = $DomainCreds
        }

        xWebsite ProbeWebSite 
        {
            Ensure          = 'Present'
            Name            = 'Probe Web Site'
            State           = 'Started'
            PhysicalPath    = 'C:\inetpub\wwwroot'
            BindingInfo     = MSFT_xWebBindingInformation
            {
                Protocol              = 'http'
                Port                  = $ProbePort
                IPAddress             = '*'
            }
            DependsOn       = '[xDnsRecord]GlobalDNS'
        }

        xFirewall DatabaseEngineFirewallRule
        {
            Direction = "Inbound"
            Name = "IIS Probe"
            DisplayName = "IIS Probe"
            Group = "TFS"
            Enabled = "True"
            Protocol = "TCP"
            LocalPort = $ProbePort
            Ensure = "Present"
            DependsOn       = '[xWebsite]ProbeWebSite'             
        }

        Script Reboot
        {
            TestScript = {
                return (Test-Path HKLM:\SOFTWARE\MyMainKey\RebootKey)
            }
            SetScript = {
                New-Item -Path HKLM:\SOFTWARE\MyMainKey\RebootKey -Force
                 $global:DSCMachineStatus = 1 
    
            }
            GetScript = { return @{result = 'result'}}
            DependsOn = '[xFirewall]DatabaseEngineFirewallRule'
        }

        xPendingReboot PostConfigReboot {
            Name = "Check for a pending reboot before changing anything"
            DependsOn = "[Script]Reboot"
        }
    }
}