[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$SourceTagName,

    [Parameter(Position = 1)]
    [AllowEmptyString()]
    [string]$TargetTagName = "",

    [string]$ApiToken,

    [string]$ServerUrl,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PageSize = 500

function Get-AuthConfig {
    $authPath = Join-Path -Path $PSScriptRoot -ChildPath "auth.json"

    if (-not (Test-Path -LiteralPath $authPath)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Failed to read auth.json at '$authPath': $($_.Exception.Message)"
    }
}

function Resolve-AuthValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ParameterValue,
        [object]$AuthConfig
    )

    if (-not [string]::IsNullOrWhiteSpace($ParameterValue)) {
        return $ParameterValue
    }

    if ($null -ne $AuthConfig) {
        $property = $AuthConfig.PSObject.Properties[$Name]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }

    throw "$Name is required. Pass -$Name or set '$Name' in auth.json."
}

function Get-EmbyBaseUrl {
    param([string]$Url)

    $trimmed = $Url.TrimEnd("/")
    if ($trimmed -match "/emby$") {
        return $trimmed
    }

    return "$trimmed/emby"
}

function ConvertTo-QueryString {
    param([hashtable]$Query)

    if (-not $Query -or $Query.Count -eq 0) {
        return ""
    }

    $parts = @(foreach ($key in $Query.Keys) {
        $value = $Query[$key]
        if ($null -eq $value) {
            continue
        }

        if ($value -is [array]) {
            $value = ($value -join ",")
        }

        "{0}={1}" -f [uri]::EscapeDataString([string]$key), [uri]::EscapeDataString([string]$value)
    })

    if ($parts.Count -eq 0) {
        return ""
    }

    return "?" + ($parts -join "&")
}

function Invoke-EmbyApi {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("GET", "POST")]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [hashtable]$Query,

        [object]$Body
    )

    $uri = $script:BaseUrl + $Path + (ConvertTo-QueryString -Query $Query)
    $params = @{
        Method  = $Method
        Uri     = $uri
        Headers = $script:Headers
    }

    if ($PSBoundParameters.ContainsKey("Body")) {
        $params.ContentType = "application/json; charset=utf-8"
        $params.Body = $Body | ConvertTo-Json -Depth 20
    }

    Invoke-RestMethod @params
}

function Get-ItemsFromResponse {
    param([object]$Response)

    if ($null -eq $Response) {
        return @()
    }

    $itemsProperty = $Response.PSObject.Properties["Items"]
    if ($null -ne $itemsProperty -and $null -ne $Response.Items) {
        return @($Response.Items)
    }

    if ($Response -is [array]) {
        return @($Response)
    }

    return @($Response)
}

function Get-TotalRecordCount {
    param([object]$Response)

    if ($null -eq $Response) {
        return $null
    }

    $property = $Response.PSObject.Properties["TotalRecordCount"]
    if ($null -ne $property) {
        return [int]$Response.TotalRecordCount
    }

    return $null
}

function Get-ItemsWithTag {
    param([Parameter(Mandatory = $true)][string]$TagName)

    $items = @()
    $startIndex = 0

    do {
        $response = Invoke-EmbyApi -Method GET -Path "/Items" -Query @{
            Recursive    = "true"
            Tags         = $TagName
            StartIndex   = $startIndex
            Limit        = $PageSize
            Fields       = "Tags,Path"
            EnableImages = "false"
        }

        $pageItems = @(Get-ItemsFromResponse -Response $response)
        $items += $pageItems

        $totalRecordCount = Get-TotalRecordCount -Response $response
        $startIndex += $pageItems.Count

        if ($pageItems.Count -eq 0) {
            break
        }
    } while ($null -ne $totalRecordCount -and $startIndex -lt $totalRecordCount)

    return @($items | Sort-Object Id -Unique)
}

function Get-TagsByName {
    param([Parameter(Mandatory = $true)][string]$TagName)

    $matchedTags = @()
    $startIndex = 0

    do {
        $response = Invoke-EmbyApi -Method GET -Path "/Tags" -Query @{
            SearchTerm = $TagName
            StartIndex = $startIndex
            Limit      = $PageSize
        }

        $pageItems = @(Get-ItemsFromResponse -Response $response)
        $matchedTags += @($pageItems | Where-Object { $_.Name -eq $TagName })

        $totalRecordCount = Get-TotalRecordCount -Response $response
        $startIndex += $pageItems.Count

        if ($pageItems.Count -eq 0) {
            break
        }
    } while ($null -ne $totalRecordCount -and $startIndex -lt $totalRecordCount)

    return @($matchedTags | Sort-Object Id -Unique)
}

function Confirm-Operation {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$ExpectedText
    )

    if ($Force -or $WhatIfPreference) {
        return
    }

    Write-Host ""
    Write-Host $Message
    Write-Host "Type '$ExpectedText' to continue. Anything else will cancel."
    $answer = Read-Host "Confirm"
    if ($answer -ne $ExpectedText) {
        throw "Cancelled by user."
    }
}

function Test-ItemHasTag {
    param(
        [Parameter(Mandatory = $true)][object]$Item,
        [Parameter(Mandatory = $true)][string]$TagName
    )

    $tagProperty = $Item.PSObject.Properties["Tags"]
    if ($null -eq $tagProperty -or $null -eq $Item.Tags) {
        return $false
    }

    return @($Item.Tags) -contains $TagName
}

function Add-TagToItem {
    param(
        [Parameter(Mandatory = $true)][object]$Item,
        [Parameter(Mandatory = $true)][string]$TagName
    )

    if (Test-ItemHasTag -Item $Item -TagName $TagName) {
        return "Skipped"
    }

    if ($PSCmdlet.ShouldProcess("$($Item.Name) [$($Item.Id)]", "Add Emby tag '$TagName'")) {
        [void](Invoke-EmbyApi -Method POST -Path "/Items/$($Item.Id)/Tags/Add" -Body @{
            Tags = @(
                @{
                    Name = $TagName
                }
            )
        })
        return "Updated"
    }

    return "WouldUpdate"
}

function Remove-TagFromItem {
    param(
        [Parameter(Mandatory = $true)][object]$Item,
        [Parameter(Mandatory = $true)][string]$TagName
    )

    if ($PSCmdlet.ShouldProcess("$($Item.Name) [$($Item.Id)]", "Remove Emby tag '$TagName'")) {
        [void](Invoke-EmbyApi -Method POST -Path "/Items/$($Item.Id)/Tags/Delete" -Body @{
            Tags = @(
                @{
                    Name = $TagName
                }
            )
        })
        return "Updated"
    }

    return "WouldUpdate"
}

if ([string]::IsNullOrWhiteSpace($SourceTagName)) {
    throw "SourceTagName cannot be empty."
}

$isDeleteOnly = [string]::IsNullOrWhiteSpace($TargetTagName)
if (-not $isDeleteOnly -and $SourceTagName -eq $TargetTagName) {
    throw "SourceTagName and TargetTagName are the same tag name. Nothing to rename."
}

$authConfig = Get-AuthConfig
$ApiToken = Resolve-AuthValue -Name "ApiToken" -ParameterValue $ApiToken -AuthConfig $authConfig
$ServerUrl = Resolve-AuthValue -Name "ServerUrl" -ParameterValue $ServerUrl -AuthConfig $authConfig

$script:BaseUrl = Get-EmbyBaseUrl -Url $ServerUrl
$script:Headers = @{
    "X-Emby-Token" = $ApiToken
    "Accept"       = "application/json"
}

$sourceTagRecords = @(Get-TagsByName -TagName $SourceTagName)
$items = @(Get-ItemsWithTag -TagName $SourceTagName)

if ($items.Count -eq 0 -and $sourceTagRecords.Count -eq 0) {
    Write-Host "No tag records or items found for '$SourceTagName'."
    exit 0
}

if ($isDeleteOnly) {
    Write-Host "Found $($sourceTagRecords.Count) tag record(s) named '$SourceTagName'."
    Write-Host "Found $($items.Count) item(s) with tag '$SourceTagName'. Removing tag from all matching items."
    Confirm-Operation -Message "This will remove tag '$SourceTagName' from $($items.Count) item(s)." -ExpectedText "YES"
}
else {
    Write-Host "Found $($sourceTagRecords.Count) tag record(s) named '$SourceTagName'."
    Write-Host "Found $($items.Count) item(s) with tag '$SourceTagName'. Renaming to '$TargetTagName' by adding '$TargetTagName' and removing '$SourceTagName'."
    Confirm-Operation -Message "This will rename tag '$SourceTagName' to '$TargetTagName' on $($items.Count) item(s)." -ExpectedText "YES"
}

$added = 0
$addSkipped = 0
$removed = 0
$failed = 0

foreach ($item in $items) {
    try {
        if (-not $isDeleteOnly) {
            $addStatus = Add-TagToItem -Item $item -TagName $TargetTagName
            if ($addStatus -eq "Updated" -or $addStatus -eq "WouldUpdate") {
                $added++
            }
            else {
                $addSkipped++
            }
        }

        $removeStatus = Remove-TagFromItem -Item $item -TagName $SourceTagName
        if ($removeStatus -eq "Updated" -or $removeStatus -eq "WouldUpdate") {
            $removed++
        }

        Write-Host "Processed: $($item.Name) [$($item.Type)] Id=$($item.Id)"
    }
    catch {
        $failed++
        Write-Warning "Failed: $($item.Name) Id=$($item.Id): $($_.Exception.Message)"
    }
}

$remainingSourceTagRecords = @(Get-TagsByName -TagName $SourceTagName)

Write-Host ""
if ($isDeleteOnly) {
    Write-Host "Done. Removed=$removed Failed=$failed"
}
else {
    Write-Host "Done. Added=$added AddSkipped=$addSkipped Removed=$removed Failed=$failed"
}

if ($remainingSourceTagRecords.Count -gt 0) {
    Write-Warning "Tag record '$SourceTagName' still exists in Emby after item tag removal. It will be cleaned automatically after several hours."
}
else {
    Write-Host "Source tag record '$SourceTagName' is no longer returned by /Tags."
}
