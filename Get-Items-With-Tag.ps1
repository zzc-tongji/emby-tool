[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias("Tag")]
    [string]$TagName,

    [string]$ApiToken,

    [string]$ServerUrl,

    [string]$ServerId,

    [AllowEmptyString()]
    [ValidateSet("", "md", "json")]
    [string]$Format = "",

    [string]$Output
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

function Resolve-OptionalAuthValue {
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

    return ""
}

function Get-EmbyBaseUrl {
    param([string]$Url)

    $trimmed = $Url.TrimEnd("/")
    if ($trimmed -match "/emby$") {
        return $trimmed
    }

    return "$trimmed/emby"
}

function Get-EmbyWebUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$ItemId,
        [Parameter(Mandatory = $true)][string]$EmbyServerId
    )

    $serverRoot = $Url.TrimEnd("/") -replace "/emby$", ""
    return "{0}/web/index.html#!/item?id={1}&serverId={2}" -f `
        $serverRoot, `
        [uri]::EscapeDataString($ItemId), `
        [uri]::EscapeDataString($EmbyServerId)
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

function Invoke-EmbyGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [hashtable]$Query
    )

    $uri = $script:BaseUrl + $Path + (ConvertTo-QueryString -Query $Query)
    Invoke-RestMethod -Method GET -Uri $uri -Headers $script:Headers
}

function Normalize-MediaLocation {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    return $Path -replace "\\", "/"
}

function Get-ItemMediaLocation {
    param([object]$Item)

    $pathProperty = $Item.PSObject.Properties["Path"]
    if ($null -ne $pathProperty -and -not [string]::IsNullOrWhiteSpace([string]$Item.Path)) {
        $mediaPath = [string]$Item.Path
        $mediaLocation = Split-Path -Path $mediaPath -Parent

        if (-not [string]::IsNullOrWhiteSpace($mediaLocation)) {
            return Normalize-MediaLocation -Path $mediaLocation
        }

        return Normalize-MediaLocation -Path $mediaPath
    }

    return ""
}

function Get-ItemsWithTag {
    param([Parameter(Mandatory = $true)][string]$Tag)

    $items = @()
    $startIndex = 0

    do {
        $response = Invoke-EmbyGet -Path "/Items" -Query @{
            Recursive    = "true"
            Tags         = $Tag
            StartIndex   = $startIndex
            Limit        = $PageSize
            Fields       = "Path"
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

    return @($items | Sort-Object Name, Id -Unique)
}

function Test-TagExists {
    param([Parameter(Mandatory = $true)][string]$Tag)

    $startIndex = 0

    do {
        $response = Invoke-EmbyGet -Path "/Tags" -Query @{
            SearchTerm = $Tag
            StartIndex = $startIndex
            Limit      = $PageSize
        }

        $pageItems = @(Get-ItemsFromResponse -Response $response)
        if (@($pageItems | Where-Object { $_.Name -eq $Tag }).Count -gt 0) {
            return $true
        }

        $totalRecordCount = Get-TotalRecordCount -Response $response
        $startIndex += $pageItems.Count

        if ($pageItems.Count -eq 0) {
            break
        }
    } while ($null -ne $totalRecordCount -and $startIndex -lt $totalRecordCount)

    return $false
}

function Escape-MarkdownCell {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return ([string]$Value) -replace "\r?\n", "<br>" -replace "\|", "\|"
}

function Escape-MarkdownLinkUrl {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return ([string]$Value) -replace "\)", "%29"
}

function ConvertTo-FriendlyText {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$Tag,
        [bool]$IncludeUrl
    )

    $lines = @(
        "Tag: $Tag"
        "Items: $($Rows.Count)"
        ""
    )

    foreach ($row in $Rows) {
        $lines += $row.Name
        $lines += "  Id: $($row.Id)"
        if ($IncludeUrl) {
            $lines += "  Url: $($row.Url)"
        }
        $lines += "  MediaLocation: $($row.MediaLocation)"
        $lines += ""
    }

    return ($lines -join [Environment]::NewLine).TrimEnd()
}

function ConvertTo-MarkdownTable {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$Tag,
        [bool]$IncludeUrl
    )

    $lines = @(
        "# Items with tag: $Tag"
        ""
        "Total: $($Rows.Count)"
        ""
    )

    $lines += @(
        "| Name | Id | Media Location |"
        "| --- | --- | --- |"
    )

    foreach ($row in $Rows) {
        $idCell = Escape-MarkdownCell -Value $row.Id
        if ($IncludeUrl) {
            $idCell = "[{0}]({1})" -f $idCell, (Escape-MarkdownLinkUrl -Value $row.Url)
        }

        $lines += "| {0} | {1} | {2} |" -f `
            (Escape-MarkdownCell -Value $row.Name), `
            $idCell, `
            (Escape-MarkdownCell -Value $row.MediaLocation)
    }

    return $lines -join [Environment]::NewLine
}

function Resolve-OutputPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path -Path (Get-Location) -ChildPath $Path
}

function Get-SafeFileNamePart {
    param([Parameter(Mandatory = $true)][string]$Value)

    $safe = $Value
    foreach ($char in [IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace([string]$char, "_")
    }

    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "tag"
    }

    return $safe
}

function Get-DefaultOutputPath {
    param(
        [Parameter(Mandatory = $true)][string]$OutputFormat,
        [Parameter(Mandatory = $true)][string]$Tag
    )

    $safeTag = Get-SafeFileNamePart -Value $Tag

    switch ($OutputFormat) {
        "md" {
            return Join-Path -Path (Get-Location) -ChildPath "items-with-tag.$safeTag.md"
        }
        "json" {
            return Join-Path -Path (Get-Location) -ChildPath "items-with-tag.$safeTag.json"
        }
    }
}

function ConvertTo-FormattedOutput {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$OutputFormat,

        [Parameter(Mandatory = $true)]
        [string]$Tag,

        [bool]$IncludeUrl
    )

    switch ($OutputFormat) {
        "" {
            return ConvertTo-FriendlyText -Rows $Rows -Tag $Tag -IncludeUrl $IncludeUrl
        }
        "md" {
            return ConvertTo-MarkdownTable -Rows $Rows -Tag $Tag -IncludeUrl $IncludeUrl
        }
        "json" {
            return $Rows | ConvertTo-Json -Depth 10
        }
    }
}

if ([string]::IsNullOrWhiteSpace($TagName)) {
    throw "TagName cannot be empty."
}

$authConfig = Get-AuthConfig
$ApiToken = Resolve-AuthValue -Name "ApiToken" -ParameterValue $ApiToken -AuthConfig $authConfig
$ServerUrl = Resolve-AuthValue -Name "ServerUrl" -ParameterValue $ServerUrl -AuthConfig $authConfig
$ServerId = Resolve-OptionalAuthValue -Name "ServerId" -ParameterValue $ServerId -AuthConfig $authConfig
$includeUrl = -not [string]::IsNullOrWhiteSpace($ServerId)

$script:BaseUrl = Get-EmbyBaseUrl -Url $ServerUrl
$script:Headers = @{
    "X-Emby-Token" = $ApiToken
    "Accept"       = "application/json"
}

if (-not (Test-TagExists -Tag $TagName)) {
    Write-Error "Tag '$TagName' was not found."
    exit 1
}

$items = @(Get-ItemsWithTag -Tag $TagName)
$outputRows = @($items | ForEach-Object {
    $row = [ordered]@{
        Id        = $_.Id
        Name      = $_.Name
        MediaLocation = Get-ItemMediaLocation -Item $_
    }

    if ($includeUrl) {
        $row["Url"] = Get-EmbyWebUrl -Url $ServerUrl -ItemId $_.Id -EmbyServerId $ServerId
    }

    [pscustomobject]$row
})

$formattedOutput = ConvertTo-FormattedOutput -Rows $outputRows -OutputFormat $Format -Tag $TagName -IncludeUrl $includeUrl

if ([string]::IsNullOrEmpty($Format)) {
    $formattedOutput
}
else {
    if ([string]::IsNullOrWhiteSpace($Output)) {
        $outputPath = Get-DefaultOutputPath -OutputFormat $Format -Tag $TagName
    }
    else {
        $outputPath = Resolve-OutputPath -Path $Output
    }

    $outputDirectory = Split-Path -Path $outputPath -Parent

    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }

    $formattedOutput | Set-Content -LiteralPath $outputPath -Encoding UTF8
}
