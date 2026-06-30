[CmdletBinding()]
param(
    [string]$ApiToken,

    [string]$ServerUrl,

    [AllowEmptyString()]
    [ValidateSet("", "md", "csv", "json")]
    [string]$Format = "",

    [string]$Output
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$VideoTypes = @("Movie", "Episode", "Video", "MusicVideo")
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

    $uri = $baseUrl + $Path + (ConvertTo-QueryString -Query $Query)
    Invoke-RestMethod -Method GET -Uri $uri -Headers $headers
}

function Get-VideoCountByTag {
    param([Parameter(Mandatory = $true)][string]$TagName)

    $response = Invoke-EmbyGet -Path "/Items" -Query @{
        Recursive        = "true"
        Tags             = $TagName
        IncludeItemTypes = $VideoTypes
        StartIndex       = 0
        Limit            = 1
        EnableImages     = "false"
    }

    $totalRecordCount = Get-TotalRecordCount -Response $response
    if ($null -ne $totalRecordCount) {
        return $totalRecordCount
    }

    return @(Get-ItemsFromResponse -Response $response).Count
}

function ConvertTo-MarkdownTable {
    param([object[]]$Rows)

    function Escape-MarkdownCell {
        param([object]$Value)

        if ($null -eq $Value) {
            return ""
        }

        return ([string]$Value) -replace "\r?\n", "<br>" -replace "\|", "\|"
    }

    $lines = @(
        "| Name | Id | VideoCount |"
        "| --- | --- | ---: |"
    )

    foreach ($row in $Rows) {
        $lines += "| {0} | {1} | {2} |" -f `
            (Escape-MarkdownCell -Value $row.Name), `
            (Escape-MarkdownCell -Value $row.Id), `
            (Escape-MarkdownCell -Value $row.VideoCount)
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

function Get-DefaultOutputPath {
    param([Parameter(Mandatory = $true)][string]$OutputFormat)

    switch ($OutputFormat) {
        "md" {
            return Join-Path -Path (Get-Location) -ChildPath "tag.md"
        }
        "csv" {
            return Join-Path -Path (Get-Location) -ChildPath "tag.csv"
        }
        "json" {
            return Join-Path -Path (Get-Location) -ChildPath "json.csv"
        }
    }
}

function ConvertTo-FormattedOutput {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$OutputFormat
    )

    switch ($OutputFormat) {
        "" {
            return $Rows
        }
        "md" {
            return ConvertTo-MarkdownTable -Rows $Rows
        }
        "csv" {
            return $Rows | ConvertTo-Csv -NoTypeInformation
        }
        "json" {
            return $Rows | ConvertTo-Json -Depth 10
        }
    }
}

$authConfig = Get-AuthConfig
$ApiToken = Resolve-AuthValue -Name "ApiToken" -ParameterValue $ApiToken -AuthConfig $authConfig
$ServerUrl = Resolve-AuthValue -Name "ServerUrl" -ParameterValue $ServerUrl -AuthConfig $authConfig

$baseUrl = Get-EmbyBaseUrl -Url $ServerUrl
$headers = @{
    "X-Emby-Token" = $ApiToken
    "Accept"       = "application/json"
}

$allTags = @()
$startIndex = 0

do {
    $query = @{
        StartIndex = $startIndex
        Limit      = $PageSize
    }

    $response = Invoke-EmbyGet -Path "/Tags" -Query $query
    $pageItems = @(Get-ItemsFromResponse -Response $response)

    $allTags += $pageItems
    $totalRecordCount = Get-TotalRecordCount -Response $response
    $startIndex += $pageItems.Count

    if ($pageItems.Count -eq 0) {
        break
    }
} while ($null -ne $totalRecordCount -and $startIndex -lt $totalRecordCount)

$allTags = @($allTags | Sort-Object Name -Unique)
$outputRows = @($allTags | ForEach-Object {
    [pscustomobject]@{
        Name       = $_.Name
        Id         = $_.Id
        VideoCount = Get-VideoCountByTag -TagName $_.Name
    }
} | Sort-Object @{Expression = "VideoCount"; Descending = $true}, @{Expression = "Name"; Descending = $false})

$formattedOutput = ConvertTo-FormattedOutput -Rows $outputRows -OutputFormat $Format

if ([string]::IsNullOrEmpty($Format)) {
    $formattedOutput
}
else {
    if ([string]::IsNullOrWhiteSpace($Output)) {
        $outputPath = Get-DefaultOutputPath -OutputFormat $Format
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
