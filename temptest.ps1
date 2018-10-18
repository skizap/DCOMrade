<#
.SYNOPSIS
Powershell script for checking possibly vulnerable DCOM applications.

.DESCRIPTION
This script is able to check if the external RPC allow Firewall rule is present in the target machine. Make sure you are able to use PSRemoting

The RPC connection can be recognized in the Windows Firewall with the following query:
v2.10|Action=Allow|Active=TRUE|Dir=In|Protocol=6|LPort=RPC

The Windows registry holds this value at the following location:
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\services\SharedAccess\Parameters\FirewallPolicy\FirewallRules

If the rule is not present it is added with the following Powershell oneliner:
New-ItemProperty -Path HKLM:\System\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules -Name RPCtest -PropertyType String -Value 'v2.10|Action=Allow|Active=TRUE|Dir=In|Protocol=6|LPort=RPC|App=any|Svc=*|Name=Allow RPC IN|Desc=custom RPC allow|'

.PARAMETER computername
The computername of the victim machine

.PARAMETER user
The username of the victim

.PARAMETER interactive
Set this to $True if you want an interactive session with the machine

.EXAMPLE
PS > Check-RemoteRPC.ps1 -computername victim -user alice
Use this above command and parameters to start a non-interactive session

.EXAMPLE
PS > Check-RemoteRPC.ps1 -computername victim -user alice -interactive $True
Use this command and parameters to start a interactive session

.LINK
https://github.com/sud0woodo

.NOTES 
Access to the local/domain administrator account on the target machine is needed to enable PSRemoting and check/change the Firewall rules.
To enable the features needed, execute the following commands:

PS > Enable-PSRemoting -SkipNetworkProfileCheck -Force
PS > Set-NetFirewallRule -Name "WINRM-HTTP-In-TCP-PUBLIC" -RemoteAddress Any

Author: sud0woodo
#>

# Assign arguments to parameters
param(
    [Parameter(Mandatory=$True,Position=1)]
    [String]$computername,

    [Parameter(Mandatory=$True,Position=2)]
    [String]$user,

    [Parameter(Mandatory=$False,Position=3)]
    [Boolean]$interactive
    )

# Create a new non-interactive Remote Powershell Session
function Get-NonInteractiveSession {
    Try {
        Write-Host "[i] Connecting to $computername" -ForegroundColor Yellow
        $session = New-PSSession -ComputerName $computername -Credential $computername\$user -ErrorAction Stop
        Write-Host "[+] Connected to $computername" -ForegroundColor Green
        return $session
    } Catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
        Write-Host "[!] Creation of Remote Session failed, Access is denied." -ForegroundColor Red
        Write-Host "[!] Exiting..." -ForegroundColor Red
        Break
    }
}

# Create a new interactive Remote Powershell Session
function Get-InteractiveSession {
    Try {
        Write-Host "[i] Connecting to $computername" -ForegroundColor Yellow
        $session = Enter-PSSession -ComputerName $computername -Credential $computername\$user -ErrorAction Stop
        Write-Host "[+] Connected to $computername" -ForegroundColor Green
        return $session
    } Catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
        Write-Host "[!] Creation of Remote Session failed, Access is denied." -ForegroundColor Red
        Write-Host "[!] Make sure PSRemoting and WINRM is enabled on the target system!" -ForegroundColor Yellow
        Write-Host "[!] Exiting..." -ForegroundColor Red
        Break
    }
}

# Check if the RPC firewall rule is present, returns True if it accepts external connections, False if the rule is not present
function Get-RPCRule($remotesession) {
    Write-Host "[i] Checking if $computername allows External RPC connections..." -ForegroundColor Yellow
    $CheckRPCRule = Invoke-Command -Session $remotesession {Get-ItemProperty -Path Registry::HKLM\System\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules | ForEach-Object {$_ -Match 'v2.10\|Action=Allow\|Active=TRUE\|Dir=In\|Protocol=6\|LPort=RPC'}}

    if ($CheckRPCRule -eq $True) {
        Write-Host "[+] $computername allows external RPC connections!" -ForegroundColor Green
    } else {
        Write-Host "[!] External RPC Firewall rule not found!" -ForegroundColor Red
        Try {
            Write-Host "[+] Attempting to add Firewall rule..." -ForegroundColor Yellow
            Invoke-Command -Session $remotesession -ScriptBlock {New-ItemProperty -Path HKLM:\System\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules -Name RPCtest -PropertyType String -Value 'v2.10|Action=Allow|Active=TRUE|Dir=In|Protocol=6|LPort=RPC|App=any|Svc=*|Name=Allow RPC IN|Desc=custom RPC allow|'}
            Write-Host "[+] Firewall rule added!" -ForegroundColor Green
        } Catch {
            Write-Host "[!] Failed to add RPC allow Firewall Rule!" -ForegroundColor Red
            Write-Host "[!] Exiting..." -ForegroundColor Red
            Break
        }
    }
}

# Check the DCOM applications on the target system and write these to a textfile
function Get-DCOMApplication($remotesession) {
    Write-Host "[i] Retrieving DCOM applications." -ForegroundColor Yellow
    $DCOMApplications = Invoke-Command -Session $remotesession -ScriptBlock {Get-CimInstance Win32_DCOMapplication}
    Try {
        Out-File -FilePath .\DCOM_Applications_$computername.txt -InputObject $DCOMApplications -Encoding ascii -ErrorAction Stop
    } Catch [System.IO.IOException] {
        Write-Host "[!] Failed to write output to file!" -ForegroundColor Red
        Write-Host "[!] Exiting..."
        Break
    }
    Write-Host "[+] DCOM applications retrieved and written to file." -ForegroundColor Green  
}

# Function that checks for the default permissions parameter in the registry and cross references this with the available DCOM Applications on the system
function Get-Vulnerable($remotesession) {
    Invoke-Command -Session $remotesession -ScriptBlock {New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT} | Out-Null

    Invoke-Command -Session $remotesession -ScriptBlock {Get-ChildItem -Path HKCR:\AppID\ | ForEach-Object { if (-Not ($_.Property -Match "LaunchPermission")) { Write-Host $($_.Name.Replace("HKEY_CLASSES_ROOT\AppID\",""))}}} -OutVariable DefaultPermissionsAppID | Out-Null 

    $DCOMApplications = Invoke-Command -Session $remotesession -ScriptBlock {Get-CimInstance Win32_DCOMapplication}
    $PossibleVulnerable = $DCOMApplications | Select-String -Pattern $DefaultPermissionsAppID
    Write-Host "[+] Found $($PossibleVulnerable.Count) DCOM applications with default launch permissions:" -ForegroundColor Green

    $PossibleVulnerable
}

if ($interactive) {
    Write-Host "[+] Attempting interactive session with $computername" -ForegroundColor Yellow
    $session = Get-InteractiveSession
} else {
    Write-Host "[+] Attempting non-interactive session with $computername" -ForegroundColor Yellow
    $session = Get-NonInteractiveSession
}

Get-RPCRule($session)
Get-DCOMApplication($session)
Get-Vulnerable($session)