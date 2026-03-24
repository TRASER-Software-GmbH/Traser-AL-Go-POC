$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

$containerName = "pr$($ENV:PR_NUMBER)"
$credential = New-Object PSCredential $ENV:CONTAINER_USERNAME (ConvertTo-SecureString $ENV:CONTAINER_PASSWORD -AsPlainText -Force)
$bcLicense = $ENV:BC_LICENSE
$bcVersion = $ENV:BC_VERSION

if (-not $bcLicense) {
    throw "Cannot bind argument to parameter 'BcLicense' because it is an empty string."
}

Write-Host "Creating PR container: $containerName"

# Determine artifact URL
if ($bcVersion) {
    $artifactUrl = Get-BCArtifactUrl -type OnPrem -version $bcVersion -select Latest
} else {
    $artifactUrl = Get-BCArtifactUrl -type OnPrem -select Latest
}
Write-Host "Using artifact: $artifactUrl"

# Check if container already exists
if (Test-BcContainer -containerName $containerName) {
    Write-Host "Container $containerName already exists - updating"
    Start-BcContainer -containerName $containerName -ErrorAction SilentlyContinue
    Import-BcContainerLicense -containerName $containerName -licenseFile $bcLicense

    # Uninstall TRASER apps for reinstall
    Get-BcContainerAppInfo -containerName $containerName -tenantSpecificProperties |
        Where-Object { $_.Publisher -eq "TRASER Software GmbH" -and $_.IsInstalled } |
        ForEach-Object {
            Write-Host "  Uninstalling $($_.Name)"
            UnInstall-BcContainerApp -containerName $containerName -name $_.Name -Force -ErrorAction SilentlyContinue
            UnPublish-BcContainerApp -containerName $containerName -name $_.Name -ErrorAction SilentlyContinue
        }
} else {
    Write-Host "Creating new container $containerName"

    $parameters = @{
        accept_eula         = $true
        containerName       = $containerName
        artifactUrl         = $artifactUrl
        credential          = $credential
        auth                = "NavUserPassword"
        licenseFile         = $bcLicense
        includeTestToolkit  = $true
        includeTestLibrariesOnly = $true
        accept_outdated     = $true
        updateHosts         = $true
        accept_insiderEula  = $true
    }

    # Add Traefik if domain is configured
    $traefikDomain = $ENV:TRAEFIK_DOMAIN
    if ($traefikDomain) {
        $parameters["useTraefik"] = $true
        $parameters["PublicDnsName"] = $traefikDomain
    }

    # Add BAK folder if configured
    $bakFolder = $ENV:BAK_FOLDER
    if ($bakFolder -and (Test-Path $bakFolder)) {
        $parameters["bakFolder"] = $bakFolder
    }

    New-BcContainer @parameters

    # Configure timeouts if Traefik is enabled
    if ($traefikDomain) {
        Invoke-ScriptInBcContainer -containerName $containerName -usePwsh $false -scriptblock {
            Param($webServerInstance)
            Set-NAVWebServerInstanceConfiguration -WebServerInstance $webServerInstance -KeyName "SessionTimeout" -KeyValue "23:59:59"
            Set-NAVServerConfiguration $ServerInstance -KeyName "SqlConnectionIdleTimeout" -KeyValue "23:59:59" -ErrorAction Continue
            Set-NAVServerConfiguration $ServerInstance -KeyName "SqlCommandTimeout" -KeyValue "03:00:00" -ErrorAction Continue
            Restart-NAVServerInstance $serverInstance
            while (Get-NavTenant $serverInstance | Where-Object { $_.State -eq "Mounting" }) {
                Start-Sleep -Seconds 1
            }
        } -argumentList $containerName
    }
}

$traefikDomain = $ENV:TRAEFIK_DOMAIN
if ($traefikDomain) {
    Write-Host "PR Container ready: https://$containerName.$traefikDomain/BC/"
} else {
    Write-Host "PR Container ready: $containerName"
}
