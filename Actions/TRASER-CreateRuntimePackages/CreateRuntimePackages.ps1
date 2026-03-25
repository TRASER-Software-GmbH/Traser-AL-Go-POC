$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

$compiledAppsFolder = $ENV:COMPILED_APPS_FOLDER
$targetBCVersions = $ENV:TARGET_BC_VERSIONS | ConvertFrom-Json
$runtimesValidFrom = [Version]$ENV:RUNTIMES_VALID_FROM
$runtimesValidTo = [Version]$ENV:RUNTIMES_VALID_TO
$runtimeValidFor = $ENV:RUNTIME_VALID_FOR
$nugetFeedUrl = $ENV:NUGET_FEED_URL
$nugetToken = $ENV:NUGET_TOKEN
$outputFolder = $ENV:OUTPUT_FOLDER
$licenseFile = $ENV:LICENSE_FILE
$country = $ENV:COUNTRY

if (!(Test-Path $outputFolder)) { New-Item -Path $outputFolder -ItemType Directory -Force | Out-Null }

$appFiles = Get-ChildItem -Path $compiledAppsFolder -Filter "*.app" -Recurse
if ($appFiles.Count -eq 0) { throw "No .app files found in $compiledAppsFolder" }

Write-Host "Found $($appFiles.Count) app(s) to create runtime packages for"
Write-Host "Target BC versions: $($targetBCVersions -join ', ')"
Write-Host "Valid from BC $runtimesValidFrom to BC $runtimesValidTo"

foreach ($bcVersion in $targetBCVersions) {
    $bcVer = [Version]$bcVersion
    Write-Host "`n=========================================="
    Write-Host "Creating runtime packages for BC $bcVersion"
    Write-Host "==========================================`n"

    $containerName = "runtime-$($bcVersion.Replace('.', ''))"
    $runtimeOutputFolder = Join-Path $outputFolder "BC$bcVersion"
    if (!(Test-Path $runtimeOutputFolder)) { New-Item -Path $runtimeOutputFolder -ItemType Directory -Force | Out-Null }

    try {
        $artifactUrl = Get-BCArtifactUrl -type OnPrem -version $bcVersion -country $country -select Latest
        Write-Host "Artifact URL: $artifactUrl"

        Convert-BcAppsToRuntimePackages `
            -containerName $containerName `
            -artifactUrl $artifactUrl `
            -licenseFile $licenseFile `
            -destinationFolder $runtimeOutputFolder `
            -apps ($appFiles | ForEach-Object { $_.FullName })

        $runtimeApps = Get-ChildItem -Path $runtimeOutputFolder -Filter "*.app" -Recurse
        Write-Host "Generated $($runtimeApps.Count) runtime app(s) for BC $bcVersion"

        foreach ($runtimeApp in $runtimeApps) {
            $appJson = Get-BcContainerAppInfo -appFile $runtimeApp.FullName
            $publisher = $appJson.Publisher -replace '[^a-zA-Z0-9_\-]', ''
            $name = $appJson.Name -replace '[^a-zA-Z0-9_\-]', ''
            $id = $appJson.Id
            $appVersion = $appJson.Version

            # --- Package 1: Indirect dependency package ---
            # {publisher}.{name}.runtime.{id} versioned with app version
            # applicationDependency range covers all supported BC versions
            $indirectPackageId = "$publisher.$name.runtime.$id"

            if ($runtimesValidTo.Minor -eq 0) {
                $appDepRange = "[$($runtimesValidFrom.Major).$($runtimesValidFrom.Minor),$($runtimesValidTo.Major + 1).0)"
            } else {
                $appDepRange = "[$($runtimesValidFrom.Major).$($runtimesValidFrom.Minor),$($runtimesValidTo.Major).$($runtimesValidTo.Minor + 1))"
            }

            Write-Host "Publishing indirect package: $indirectPackageId v$appVersion (BC range: $appDepRange)"

            $indirectNupkg = New-BcNuGetPackage `
                -appfile $runtimeApp.FullName `
                -isIndirectPackage `
                -packageId "{publisher}.{name}.runtime.{id}" `
                -dependencyIdTemplate "{publisher}.{name}.runtime.{id}" `
                -applicationDependency $appDepRange

            if ($indirectNupkg) {
                Push-BcNuGetPackage -nuGetServerUrl $nugetFeedUrl -nuGetToken $nugetToken `
                    -bcNuGetPackage $indirectNupkg -SkipIfExists
            }

            # --- Package 2: Version-specific package ---
            # {publisher}.{name}.runtime-{appversion} versioned with BC version
            $versionSpecificPackageId = "$publisher.$name.runtime-$($appVersion.ToString().Replace('.', '-'))"

            switch ($runtimeValidFor) {
                'major' {
                    $bcDepRange = "[$($bcVer.Major).$($bcVer.Minor),$($bcVer.Major + 1).0)"
                }
                'minor' {
                    $bcDepRange = "[$($bcVer.Major).$($bcVer.Minor),$($bcVer.Major).$($bcVer.Minor + 1))"
                }
            }
            $platformDep = "[$($bcVer.Major).0,$($bcVer.Major + 1).0)"

            Write-Host "Publishing version-specific package: $versionSpecificPackageId v$bcVersion (BC dep: $bcDepRange)"

            $versionNupkg = New-BcNuGetPackage `
                -appfile $runtimeApp.FullName `
                -packageId "{publisher}.{name}.runtime-{version}" `
                -dependencyIdTemplate "{publisher}.{name}.runtime.{id}" `
                -packageVersion $bcVersion `
                -applicationDependency $bcDepRange `
                -platformDependency $platformDep

            if ($versionNupkg) {
                Push-BcNuGetPackage -nuGetServerUrl $nugetFeedUrl -nuGetToken $nugetToken `
                    -bcNuGetPackage $versionNupkg -SkipIfExists
            }

            Write-Host "Published runtime packages for $name (BC $bcVersion)"
        }
    }
    finally {
        if (Test-BcContainer -containerName $containerName) {
            Write-Host "Removing container $containerName"
            Remove-BcContainer -containerName $containerName
        }
    }
}

Write-Host "`nRuntime package creation complete for all BC versions"
