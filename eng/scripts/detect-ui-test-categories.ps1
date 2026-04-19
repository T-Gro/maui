[CmdletBinding()]
param(
    [string]$TargetBranch,
    [string]$TestRoot = "src/Controls/tests/TestCases.Shared.Tests"
)

$buildReason = $env:BUILD_REASON
if ([string]::IsNullOrWhiteSpace($buildReason)) {
    $buildReason = $env:SYSTEM_REASON
}

if ($buildReason -ne 'PullRequest') {
    Write-Host "Build reason '$buildReason' is not PullRequest. Skipping category detection." -ForegroundColor Cyan
    return
}

if ([string]::IsNullOrWhiteSpace($TargetBranch)) {
    $TargetBranch = $env:SYSTEM_PULLREQUEST_TARGETBRANCH
}

# Escape hatch: PR label "run-all-uitests" forces the full category matrix to run.
$prNumber = $env:SYSTEM_PULLREQUEST_PULLREQUESTNUMBER
$repoName = $env:BUILD_REPOSITORY_NAME
if (-not [string]::IsNullOrWhiteSpace($prNumber) -and -not [string]::IsNullOrWhiteSpace($repoName)) {
    try {
        $labelsUrl = "https://api.github.com/repos/$repoName/issues/$prNumber/labels"
        Write-Host "Checking PR labels at $labelsUrl" -ForegroundColor Cyan
        $headers = @{ 'User-Agent' = 'maui-ui-test-detector' }
        if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
            $headers['Authorization'] = "Bearer $env:GH_TOKEN"
        } elseif (-not [string]::IsNullOrWhiteSpace($env:SYSTEM_ACCESSTOKEN)) {
            $headers['Authorization'] = "Bearer $env:SYSTEM_ACCESSTOKEN"
        }
        $labels = Invoke-RestMethod -Uri $labelsUrl -Headers $headers -Method Get -TimeoutSec 30
        $labelNames = @($labels | ForEach-Object { $_.name })
        Write-Host "PR labels: $([string]::Join(', ', $labelNames))" -ForegroundColor Cyan
        if ($labelNames -contains 'run-all-uitests') {
            Write-Host "##[section]Label 'run-all-uitests' present. Running ALL UI test categories (detection bypassed)." -ForegroundColor Yellow
            return
        }
    } catch {
        Write-Host "##[warning]Failed to query PR labels: $($_.Exception.Message). Continuing with category detection."
    }
}

if ([string]::IsNullOrWhiteSpace($TargetBranch)) {
    Write-Host "##[warning]Unable to determine target branch for comparison."
    Write-Host "##[section]FALLBACK: All UI test categories will run for this PR."
    return
}

$targetBranch = $TargetBranch -replace '^refs/heads/', ''

Write-Host "Fetching target branch 'origin/${targetBranch}' for diff analysis..." -ForegroundColor Cyan
try {
    git fetch origin "${targetBranch}" --no-tags --prune --depth=200 | Out-Null
} catch {
    Write-Host "##[warning]Failed to fetch origin/${targetBranch}: $($_.Exception.Message)"
    Write-Host "##[section]FALLBACK: All UI test categories will run for this PR."
    return
}

$mergeBase = $null
try {
    $mergeBase = (git merge-base HEAD "origin/${targetBranch}").Trim()
} catch {
    Write-Host "##[warning]Could not determine merge base with origin/${targetBranch}: $($_.Exception.Message)"
    Write-Host "##[section]FALLBACK: All UI test categories will run for this PR."
    return
}

if ([string]::IsNullOrWhiteSpace($mergeBase)) {
    Write-Host "##[warning]Merge base calculation returned empty result."
    Write-Host "##[section]FALLBACK: All UI test categories will run for this PR."
    return
}

Write-Host "Calculating diff between $mergeBase and HEAD limited to '$TestRoot'..." -ForegroundColor Cyan
$diff = git diff --diff-filter=AMR --unified=0 $mergeBase HEAD -- "$TestRoot"
if ([string]::IsNullOrWhiteSpace($diff)) {
    Write-Host "No changes detected under '$TestRoot'. Falling back to default category matrix." -ForegroundColor Cyan
    return
}

$categoryPattern = '^\+\s*\[Category\((?<value>[^\)]*)\)\]'
$addedCategories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($line in $diff -split "`n") {
    if ($line -match $categoryPattern) {
        $rawValue = $Matches['value'].Trim()
        if ([string]::IsNullOrWhiteSpace($rawValue)) {
            continue
        }

        # Normalize value: UITestCategories.XYZ => XYZ, quoted strings => trimmed text
        if ($rawValue -match '^UITestCategories\.(?<name>[A-Za-z0-9_]+)$') {
            $category = $Matches['name']
        } elseif ($rawValue -match '^["''](?<name>[A-Za-z0-9_ -]+)["'']$') {
            $category = $Matches['name']
        } else {
            # Attempt to evaluate nameof-style constructs or fallback to raw value
            if ($rawValue -match 'nameof\(UITestCategories\.(?<name>[A-Za-z0-9_]+)\)') {
                $category = $Matches['name']
            } else {
                $message = "Unrecognized category expression '$rawValue'. Expected formats: UITestCategories.<Name>, nameof(UITestCategories.<Name>), or a quoted string."
                Write-Host "##[error]$message"
                throw $message
            }
        }

        $category = $category.Trim()
        if (-not [string]::IsNullOrWhiteSpace($category)) {
            $addedCategories.Add($category) | Out-Null
        }
    }
}

if ($addedCategories.Count -eq 0) {
    Write-Host "No new Category attributes detected in diff. Using default category matrix." -ForegroundColor Cyan
    return
}

Write-Host "Detected categories from PR changes: $([string]::Join(', ', $addedCategories))" -ForegroundColor Green

# Build matrix JSON expected by Azure Pipelines strategy matrix (CATEGORYGROUP values)
$matrix = [ordered]@{}
$index = 0
foreach ($category in ($addedCategories | Sort-Object)) {
    $key = "Category_$index"
    $matrix[$key] = @{ CATEGORYGROUP = $category }
    $index++
}

$matrixJson = $matrix | ConvertTo-Json -Depth 5

Write-Host "##vso[task.setvariable variable=UITestCategoryMatrix;isOutput=true]$matrixJson"
Write-Host "##vso[task.setvariable variable=UITestCategoryList;isOutput=true]$([string]::Join(',', ($addedCategories | Sort-Object)))"