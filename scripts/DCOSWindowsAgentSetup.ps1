[CmdletBinding(DefaultParameterSetName="Standard")]
Param(
    [ValidateNotNullOrEmpty()]
    [string]$MasterIP,
    [ValidateNotNullOrEmpty()]
    [string]$AgentPrivateIP,
    [ValidateNotNullOrEmpty()]
    [string]$BootstrapUrl,
    [AllowNull()]
    [switch]$isPublic = $false,
    [AllowNull()]
    [string]$MesosDownloadDir,
    [AllowNull()]
    [string]$MesosInstallDir,
    [AllowNull()]
    [string]$MesosLaunchDir,
    [AllowNull()]
    [string]$MesosWorkDir,
    [AllowNull()]
    [string]$customAttrs
)

$ErrorActionPreference = "Stop"

$SCRIPTS_REPO_URL = "https://github.com/dcos/dcos-windows"
$SCRIPTS_DIR = Join-Path $env:TEMP "dcos-windows"
$MESOS_BINARIES_URL = "$BootstrapUrl/mesos.zip"
$DIAGNOSTICS_BINARIES_URL = "$BootstrapUrl/diagnostics.zip"
$DCOS_NET_ZIP_PACKAGE_URL = "$BootstrapUrl/dcos-net.zip"
$METRICS_BINARIES_URL = "$BootstrapUrl/metrics.zip"

$WINDOWS_SERVER_RS3_BUILD_NUMBER = "16299"
$WINDOWS_SERVER_RS4_BUILD_NUMBER = "17134"
$WINDOWS_SERVER_RS3_DOCKER_IMAGE_TAG = "1709"
$WINDOWS_SERVER_RS4_DOCKER_IMAGE_TAG = "1803"

filter Timestamp {"[$(Get-Date -Format o)] $_"}

function Write-Log($message)
{
    $msg = $message | Timestamp
    Write-Output $msg
}

function Add-ToSystemPath {
    Param(
        [Parameter(Mandatory=$true)]
        [string[]]$Path
    )
    Write-Log "Enter Add-ToSystemPath"
    $systemPath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine').Split(';')
    $currentPath = $env:PATH.Split(';')
    foreach($p in $Path) {
        if($p -notin $systemPath) {
            $systemPath += $p
        }
        if($p -notin $currentPath) {
            $currentPath += $p
        }
    }
    $env:PATH = $currentPath -join ';'
    setx.exe /M PATH ($systemPath -join ';')
    if($LASTEXITCODE) {
        Throw "Failed to set the new system path"
    }
    Write-Log "Exit Add-ToSystemPath"
}

function Start-ExecuteWithRetry {
    Param(
        [Parameter(Mandatory=$true)]
        [Alias("Command")]
        [ScriptBlock]$ScriptBlock,
        [int]$MaxRetryCount=10,
        [int]$RetryInterval=3,
        [array]$ArgumentList=@()
    )
    $currentErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $retryCount = 0
    while ($true) {
        Write-Log "Start-ExecuteWithRetry attempt $retryCount"
        try {
            $res = Invoke-Command -ScriptBlock $ScriptBlock `
                                  -ArgumentList $ArgumentList
            $ErrorActionPreference = $currentErrorActionPreference
             Write-Log "Start-ExecuteWithRetry completed"
            return $res
        } catch [System.Exception] {
            $retryCount++
            if ($retryCount -gt $MaxRetryCount) {
                $ErrorActionPreference = $currentErrorActionPreference
                 Write-Log "Start-ExecuteWithRetry exception thrown"
                Throw
            } else {
                Write-Log "Start-ExecuteWithRetry Retry: $($_.ToString())"
                Start-Sleep $RetryInterval
            }
        }
    }
}

function Install-Git {
    Write-Log "Enter Install-Git"
    $gitInstallerURL = "https://dcos-mirror.azureedge.net/win-downloads/Git-2.14.1-64-bit.exe"
    $gitInstallDir = Join-Path $env:ProgramFiles "Git"
    $gitPaths = @("$gitInstallDir\cmd", "$gitInstallDir\bin")
    if(Test-Path $gitInstallDir) {
        Write-Log "Git is already installed"
        Add-ToSystemPath $gitPaths
        Write-Log "Exit Install-Git: already installed"
        return
    }
    Write-Log "Downloading Git from $gitInstallerURL"
    $programFile = Join-Path $env:TEMP "git.exe"
    Start-ExecuteWithRetry { Invoke-WebRequest -UseBasicParsing -Uri $gitInstallerURL -OutFile $programFile }
    $parameters = @{
        'FilePath' = $programFile
        'ArgumentList' = @("/SILENT")
        'Wait' = $true
        'PassThru' = $true
    }
    Write-Log "Installing Git"
    $p = Start-Process @parameters
    if($p.ExitCode -ne 0) {
        Throw "Failed to install Git during the environment setup"
    }
    Add-ToSystemPath $gitPaths
    Write-Log "Exit Install-Git"
}

function New-ScriptsDirectory {
    Write-Log "Enter New-ScriptsDirectory"
    if(Test-Path $SCRIPTS_DIR) {
        Remove-Item -Recurse -Force -Path $SCRIPTS_DIR
    }
    Install-Git
    Start-ExecuteWithRetry {
        $p = Start-Process -FilePath 'git.exe' -Wait -PassThru -NoNewWindow -ArgumentList @('clone', $SCRIPTS_REPO_URL, $SCRIPTS_DIR)
        if($p.ExitCode -ne 0) {
            Throw "Failed to clone $SCRIPTS_REPO_URL repository"
        }
    }
    Write-Log "Exit New-ScriptsDirectory"
}

function Get-MasterIPs {
    [string[]]$ips = ConvertFrom-Json $MasterIP
    # NOTE(ibalutoiu): ACS-Engine adds the Zookeper port to every master IP and we need only the address
    [string[]]$masterIPs = $ips | ForEach-Object { $_.Split(':')[0] }
    return ,$masterIPs
}

function Install-MesosAgent {
    Write-Log "Enter Install-MesosAgent"
    $masterIPs = Get-MasterIPs
    & "$SCRIPTS_DIR\scripts\mesos-agent-setup.ps1" -MasterAddress $masterIPs -MesosWindowsBinariesURL $MESOS_BINARIES_URL `
                                                -AgentPrivateIP $AgentPrivateIP -Public:$isPublic -CustomAttributes $customAttrs
    if($LASTEXITCODE) {
        Throw "Failed to setup the DCOS Mesos Windows slave agent"
    }
    Write-Log "Exit Install-MesosAgent"
}

function Install-ErlangRuntime {
    & "$SCRIPTS_DIR\scripts\erlang-setup.ps1"
    if($LASTEXITCODE) {
        Throw "Failed to setup the Windows Erlang runtime"
    }
}

function Install-EPMDAgent {
    & "$SCRIPTS_DIR\scripts\epmd-agent-setup.ps1"
    if($LASTEXITCODE) {
        Throw "Failed to setup the DCOS EPMD Windows agent"
    }
}

function Install-SpartanAgent {
    $masterIPs = Get-MasterIPs
    & "$SCRIPTS_DIR\scripts\spartan-agent-setup.ps1" -MasterAddress $masterIPs -AgentPrivateIP $AgentPrivateIP -Public:$isPublic
    if($LASTEXITCODE) {
        Throw "Failed to setup the DCOS Spartan Windows agent"
    }
}

function Install-AdminRouterAgent {
    Write-Log "Enter Install-AdminRouterAgent"
    & "$SCRIPTS_DIR\scripts\adminrouter-agent-setup.ps1" -AgentPrivateIP $AgentPrivateIP
    if($LASTEXITCODE) {
        Throw "Failed to setup the DCOS AdminRouter Windows agent"
    }
    Write-Log "Exit Install-AdminRouterAgent"
}

function Install-DiagnosticsAgent {
    Param(
        [bool]$IncludeMatricsService
    )
    Write-Log "Enter Install-DiagnosticsAgent"
    & "$SCRIPTS_DIR\scripts\diagnostics-agent-setup.ps1" -DiagnosticsWindowsBinariesURL $DIAGNOSTICS_BINARIES_URL -IncludeMetricsToMonitoredSericeList $IncludeMatricsService
    if($LASTEXITCODE) {
        Throw "Failed to setup the DCOS Diagnostics Windows agent"
    }
    Write-Log "Exit Install-DiagnosticsAgent"
}

function Install-DCOSNetAgent {
    Write-Log "Enter Install-DCOSNetAgent"
    & "$SCRIPTS_DIR\scripts\dcos-net-agent-setup.ps1" -AgentPrivateIP $AgentPrivateIP -DCOSNetZipPackageUrl $DCOS_NET_ZIP_PACKAGE_URL
    if($LASTEXITCODE) {
        Throw "Failed to setup the dcos-net Windows agent"
    }
    Write-Log "Exit Install-DCOSNetAgent"
}

function Install-MetricsAgent {
    Write-Log "Enter Install-MetricsAgent"
    & "$SCRIPTS_DIR\scripts\metrics-agent-setup.ps1" -MetricsWindowsBinariesURL $METRICS_BINARIES_URL
    if($LASTEXITCODE) {
        Throw "Failed to setup the DCOS Metrics Windows agent"
    }
    Write-Log "Exit Install-MetricsAgent"
}

function Configure-Docker{
    Write-Log "Enter Configure-Docker"
    . "$SCRIPTS_DIR\scripts\variables.ps1"
    $baseUrl = "${LOG_SERVER_BASE_URL}/downloads/docker"
    $version = "18.03.1-ce"

    $dockerServiceObj = Stop-Service $DOCKER_SERVICE_NAME -PassThru
    $dockerServiceObj.WaitForStatus('Stopped','00:03:00')
    if ($dockerServiceObj.Status -ne 'Stopped') { 
       Throw "Docker service failed to stop"
    } else {
        Write-Log "Docker service was stopped successfully"
    }

    # remove Docker default network: nat 
    Get-HNSNetwork | Remove-HNSNetwork
    Set-Content -Path "${DOCKER_DATA}\config\daemon.json" -Value '{ "bridge" : "none" }' -Encoding Ascii

    # update Docker binaries
    Start-ExecuteWithRetry { Invoke-WebRequest -UseBasicParsing -Uri "${baseUrl}/${version}/docker.exe" -OutFile "${DOCKER_HOME}\docker.exe" }
    Start-ExecuteWithRetry { Invoke-WebRequest -UseBasicParsing -Uri "${baseUrl}/${version}/dockerd.exe" -OutFile "${DOCKER_HOME}\dockerd.exe" }

    $dockerServiceObj = Start-Service $DOCKER_SERVICE_NAME -PassThru
    $dockerServiceObj.WaitForStatus('Running','00:03:00')
    if ($dockerServiceObj.Status -ne 'Running') { 
        Throw "Docker service failed to start"
    } else {
        Write-output "Docker service was started successfully"
    }
    Write-Log "Exit Configure-Docker"
}

function New-DockerNATNetwork {
    #
    # This needs to be used by all the containers since DCOS Spartan DNS server
    # is not bound to the gateway address.
    # The Docker gateway address is added to the DNS server list unless
    # disable_gatewaydns network option is enabled.
    #
    Write-Log "Enter New-DockerNATNetwork"
    $natNetworkName = "dcosnat"
    Start-ExecuteWithRetry {
        docker.exe network create --driver="nat" --opt "com.docker.network.windowsshim.disable_gatewaydns=true" "${natNetworkName}"
        if($LASTEXITCODE -ne 0) {
            Throw "Failed to create the new Docker NAT network with disable_gatewaydns flag"
        }
    }
    Write-Log "Exit New-DockerNATNetwork: created ${natNetworkName} network with flag: com.docker.network.windowsshim.disable_gatewaydns=true"
}

function Pull-MesosHealthCheckImage{
    Write-Log "Enter Pull-MesosHealthCheckImage"
    Start-ExecuteWithRetry {
        docker pull mesos/windows-health-check
        if($LASTEXITCODE -ne 0) {
            Throw "Failed to pull down mesos windows-health-check image"
        }
    }
    Write-Log "Exit Pull-MesosHealthCheckImage"
}

function Get-DCOSVersion {
    param([ref]$Reference)

    Write-Log "Enter Get-DCOSVersion"
    $masterIPs = Get-MasterIPs
    $timeout = 7200.0
    $startTime = Get-Date
    while(((Get-Date) - $startTime).TotalSeconds -lt $timeout) {
        foreach($ip in $masterIPs) {
            try {
                $response = Invoke-WebRequest -UseBasicParsing -Uri "http://$ip/dcos-metadata/dcos-version.json"
            } catch {
                continue
            }
            $Reference.Value = (ConvertFrom-Json -InputObject $response.Content).version
            Write-Log "Exit Get-DCOSVersion"
            return
        }
        Start-Sleep -Seconds 30
    }
    Throw "ERROR: Cannot find the DC/OS version from any of the masters $($masterIPs -join ', ') within a timeout of $timeout seconds"
}

function Get-MesosFlags {
    param([ref]$Reference)

    Write-Log "Enter Get-MesosFlags"
    $masterIPs = Get-MasterIPs
    $timeout = 7200.0
    $startTime = Get-Date
    while(((Get-Date) - $startTime).TotalSeconds -lt $timeout) {
        foreach($ip in $masterIPs) {
            try {
                $response = Invoke-WebRequest -UseBasicParsing -Uri "http://${ip}:5050/flags"
            } catch {
                continue
            }
            $Reference.Value = (ConvertFrom-Json -InputObject $response.Content).flags
            Write-Log "Exit Get-MesosFlags"
            return
        }
        Start-Sleep -Seconds 30
    }
    Throw "ERROR: Cannot find the Mesos flags from any of the masters $($masterIPs -join ', ') within a timeout of $timeout seconds"
}

function New-DCOSEnvironmentFile {
    Write-Log "Enter New-DCOSEnvironmentFile"
    . "$SCRIPTS_DIR\scripts\variables.ps1"
    if(!(Test-Path -Path $DCOS_DIR)) {
        New-Item -ItemType "Directory" -Path $DCOS_DIR
    }
    $masterIPs = Get-MasterIPs
    Write-Log "Trying to find the DC/OS version by querying the API of the masters: $($masterIPs -join ', ')"
    $dcosVersion = ""
    Get-DCOSVersion -Reference ([ref] $dcosVersion)
    Set-Content -Path $GLOBAL_ENV_FILE -Value @(
        "PROVIDER=azure",
        "DCOS_VERSION=${dcosVersion}"
    )
    Write-Log "Exit New-DCOSEnvironmentFile"
}

function New-DCOSMastersListFile {
    Write-Log "Enter New-DCOSMastersListFile"
    . "$SCRIPTS_DIR\scripts\variables.ps1"
    if(!(Test-Path -Path $DCOS_DIR)) {
        New-Item -ItemType "Directory" -Path $DCOS_DIR
    }
    $masterIPs = Get-MasterIPs
    ConvertTo-Json -InputObject $masterIPs -Compress | Out-File -Encoding ascii -PSPath $MASTERS_LIST_FILE
    Write-Log "Exit New-DCOSMastersListFile"
}

function New-DCOSServiceWrapper {
    Write-Log "Enter New-DCOSServiceWrapper"
    . "$SCRIPTS_DIR\scripts\variables.ps1"
    $parent = Split-Path -Parent -Path $SERVICE_WRAPPER
    if(!(Test-Path -Path $parent)) {
        New-Item -ItemType "Directory" -Path $parent
    }
    Start-ExecuteWithRetry { Invoke-WebRequest -UseBasicParsing -Uri $SERVICE_WRAPPER_URL -OutFile $SERVICE_WRAPPER }
    Write-Log "Exit New-DCOSServiceWrapper"
}


try {
    Write-Log "Setting up DCOS Windows Agent"
    New-ScriptsDirectory
    Configure-Docker
    New-DockerNATNetwork
    New-DCOSEnvironmentFile
    New-DCOSMastersListFile
    New-DCOSServiceWrapper
    Install-MesosAgent
    $dcosVersion = ""
    Get-DCOSVersion -Reference ([ref] $dcosVersion)
    if($dcosVersion.StartsWith("1.8") -or $dcosVersion.StartsWith("1.9") -or $dcosVersion.StartsWith("1.10")) {
        Install-ErlangRuntime
        Install-EPMDAgent
        Install-SpartanAgent
    } else {
        # DC/OS release >= 1.11
        Install-DCOSNetAgent
    }
    Install-AdminRouterAgent
    $mesosFlags = ""
    Get-MesosFlags -Reference ([ref] $mesosFlags)
    $IsMatricsServiceInstalled = $false
    if($mesosFlags.authenticate_agents -eq "false") {
        # Install Metrics only if mesos_authentication is disabled
        Install-MetricsAgent
        $IsMatricsServiceInstalled = $true 
    }
    # To get collect a complete list of services for node health monitoring,
    # the Diagnostics needs always to be the last one to install
    Install-DiagnosticsAgent -IncludeMatricsService $IsMatricsServiceInstalled
    Pull-MesosHealthCheckImage
} catch {
    Write-Log "Error in setting up DCOS Windows Agent: $($_.ToString())"
    exit 1
}
Write-Log "Successfully finished setting up DCOS Windows Agent"
exit 0
