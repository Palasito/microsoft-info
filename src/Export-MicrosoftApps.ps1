<#
        .SYNOPSIS
        Creates a list of Microsoft first party apps with app id and display name and exports to csv and json.

        .DESCRIPTION
        This scripts retrieves a list of apps in the following order
        1. Microsoft Graph (apps where appOwnerOrganizationId is Microsoft)
        2. Microsoft Entra docs (from known-guids.json in the Entra docs repository)
        3. Microsoft Learn doc (https://learn.microsoft.com/troubleshoot/azure/active-directory/verify-first-party-apps-sign-in)
        4. Custom list of apps (./customdata/MysteryApps.csv) - Community contributed list of Microsoft apps and their app ids

        This script assumes the current session is connected to Microsoft Graph with the scope Application.Read.All
        .EXAMPLE
        ./src/Export-MicrosoftApps.ps1

        Creates a list of Microsoft first party apps with output written to .\_info and custom data loaded from ./customdata/OtherMicrosoftApps.csv
        Assumes the root of the repo is the current working directory

        .EXAMPLE
        Export-MicrosoftApps.ps1 $OutputPath ".\myOutputFolder" $CustomAppDataPath "./../customdata/OtherMicrosoftApps.csv"

        Creates a list using custom folders for the output and reading of custom data
#>

param (
    [Parameter(Mandatory=$false, HelpMessage="Path to output the csv and json files")]
    [string]$OutputPath = ".\_info",

    [Parameter(Mandatory=$false, HelpMessage="Path to csv file with community contributed custom list of apps")]
    [string]$CustomAppDataPath = "./customdata/OtherMicrosoftApps.csv"
    )

function GetAppsFromMicrosoftLearnDoc() {
    Write-Debug "Retrieving apps from Microsoft Learn doc"
    $msLearnFirstPartyAppDocUri = "https://raw.githubusercontent.com/MicrosoftDocs/SupportArticles-docs/refs/heads/main/support/entra/entra-id/governance/verify-first-party-apps-sign-in.md"
    $mdContent = (Invoke-WebRequest -Uri $msLearnFirstPartyAppDocUri).Content
    $lines = $mdContent -split [Environment]::NewLine
    $tableIndex = 0
    $appList = @()
    foreach ($line in $lines) {
        $cleanLine = $line.trim()

        if ($cleanLine.startsWith("|")) {
            if ($cleanLine.startsWith("|-")) { $tableIndex++ }

            $tenantId = "f8cdef31-a31e-4b4a-93e4-5f571e91255a"
            if ($tableIndex -eq 2) { $tenantId = "72f988bf-86f1-41af-91ab-2d7cd011db47" }

            $cols = $cleanLine -split '\|'
            $appName = $cols[1].trim()
            $appId = $cols[2].trim()

            $guid = [System.Guid]::empty
            $isGuid = [System.Guid]::TryParse($appId, [System.Management.Automation.PSReference]$guid)
            if ($isGuid) {
                $itemInfo = [ordered]@{
                    appId                  = $appId + ""
                    displayName         = $appName + ""
                    appOwnerOrganizationId = $tenantId + ""
                    source                 = "Learn"
                }
                $appList += $itemInfo
            }
        }
    }
    return $appList
}

function GetAppsFromEntraDocs() {
    Write-Host "Retrieving apps from Entra documentation source"
    $docsJsonUri = "https://raw.githubusercontent.com/MicrosoftDocs/entra-docs/main/.docutune/dictionaries/known-guids.json"

    try {
        # Use -AsHashtable to handle case-insensitive keys
        $jsonContent = Invoke-WebRequest -Uri $docsJsonUri -ErrorAction Stop |
                       Select-Object -ExpandProperty Content |
                       ConvertFrom-Json -AsHashtable

        $appList = @()

        foreach ($key in $jsonContent.Keys) {
            # The key is the display name and the value is the guid/appId
            $displayName = $key
            $appId = $jsonContent[$key]

            # Verify the value is a valid GUID
            $guid = [System.Guid]::Empty
            $itemInfo = [ordered]@{
                appId                  = $appId + ""
                displayName         = $displayName + ""
                appOwnerOrganizationId = ""
                source                 = "EntraDocs"
            }
            $appList += $itemInfo
        }

        return $appList
    }
    catch {
        Write-Error "Failed to retrieve data from Entra documentation: $_"
        return @()
    }
}

function GetAppsFromMicrosoftGraph() {
    Write-Host "Retrieving apps from Microsoft Graph"
    $tenantIdList = @("f8cdef31-a31e-4b4a-93e4-5f571e91255a", "72f988bf-86f1-41af-91ab-2d7cd011db47", "cdc5aeea-15c5-4db6-b079-fcadd2505dc2")
    $select = "appId,displayName,appOwnerOrganizationId"


    foreach ($tenantId in $tenantIdList) {
        $filter = "appOwnerOrganizationId eq $($tenantId)"
        $servicePrincipals += Get-MgServicePrincipal -Filter $filter -Select $select -ConsistencyLevel eventual -PageSize 999 -CountVariable $count -All
    }

    $appList = @()

    foreach ($item in $servicePrincipals) {
        $itemInfo = [ordered]@{
            appId                  = $item.appId + ""
            displayName         = $item.displayName + ""
            appOwnerOrganizationId = $item.appOwnerOrganizationId + ""
            source                 = "Graph"
        }
        $appList += $itemInfo
    }
    return $appList
}

$appList = @()

# sources at the top take priority, duplicates from sources that are lower are skipped.
$appList += GetAppsFromMicrosoftGraph
$appList += GetAppsFromEntraDocs
$appList += GetAppsFromMicrosoftLearnDoc
$appList += Import-Csv $CustomAppDataPath | ForEach-Object { $_.displayName = $_.displayName.trim() + " [Community Contributed]"; $_ }

Write-Host "Creating unique list of apps"
$idList = @()
$uniqueAppList = @()

foreach ($item in $appList) {
    [string]$id = $item.appId

    # skip duplicates
    if ($idList -contains $id) { continue }
    $idList += $id
    $uniqueAppList += $item
}

Write-Host "Exporting to csv and json"
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

$outputFilePathCsv = Join-Path $OutputPath "MicrosoftApps.csv"
$outputFilePathJson = Join-Path $OutputPath "MicrosoftApps.json"

# Debugging
$appList | Export-Csv (Join-Path $OutputPath "MicrosoftApps.debug.csv")

$uniqueAppList | Export-Csv $outputFilePathCsv
$uniqueAppList | ConvertTo-Json | Out-File $outputFilePathJson
