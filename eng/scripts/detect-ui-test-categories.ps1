[CmdletBinding()]
param(
    [string]$TargetBranch,
    [string]$PrNumber,
    [string]$TestRoot = "src/Controls/tests/TestCases.Shared.Tests"
)

# Normalize PrNumber: strip whitespace; AzDO often passes a placeholder space when the parameter is unset.
if (-not [string]::IsNullOrWhiteSpace($PrNumber)) {
    $PrNumber = $PrNumber.Trim()
} else {
    $PrNumber = $null
}

$buildReason = $env:BUILD_REASON
if ([string]::IsNullOrWhiteSpace($buildReason)) {
    $buildReason = $env:SYSTEM_REASON
}

$isManualPrTest = -not [string]::IsNullOrWhiteSpace($PrNumber)

if ($buildReason -ne 'PullRequest' -and -not $isManualPrTest) {
    Write-Host "Build reason '$buildReason' is not PullRequest and no -PrNumber override was provided. Skipping category detection." -ForegroundColor Cyan
    return
}

if ([string]::IsNullOrWhiteSpace($TargetBranch)) {
    $TargetBranch = $env:SYSTEM_PULLREQUEST_TARGETBRANCH
}

# Determine the PR number for label / API lookups.
$prNumberForLookup = $env:SYSTEM_PULLREQUEST_PULLREQUESTNUMBER
if ([string]::IsNullOrWhiteSpace($prNumberForLookup) -and $isManualPrTest) {
    $prNumberForLookup = $PrNumber
}
$repoName = $env:BUILD_REPOSITORY_NAME
if ([string]::IsNullOrWhiteSpace($repoName)) {
    $repoName = 'dotnet/maui'
}

# Helper: build authenticated GitHub API headers.
function Get-GitHubHeaders {
    $h = @{ 'User-Agent' = 'maui-ui-test-detector' }
    if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        $h['Authorization'] = "Bearer $env:GH_TOKEN"
    } elseif (-not [string]::IsNullOrWhiteSpace($env:SYSTEM_ACCESSTOKEN)) {
        $h['Authorization'] = "Bearer $env:SYSTEM_ACCESSTOKEN"
    }
    return $h
}

# Manual-test override: when -PrNumber is provided, fetch the PR's base/head from GitHub
# and replay the same diff that a normal PR build would see.
if ($isManualPrTest) {
    try {
        $prUrl = "https://api.github.com/repos/$repoName/pulls/$PrNumber"
        Write-Host "##[section]Manual PR test mode (PrNumber=$PrNumber). Fetching PR metadata from $prUrl" -ForegroundColor Yellow
        $pr = Invoke-RestMethod -Uri $prUrl -Headers (Get-GitHubHeaders) -Method Get -TimeoutSec 30
        $TargetBranch = $pr.base.ref
        $headRef = $pr.head.ref
        $headSha = $pr.head.sha
        $baseRepoCloneUrl = $pr.base.repo.clone_url
        $headRepoCloneUrl = $pr.head.repo.clone_url
        Write-Host "PR #$PrNumber : $($pr.head.repo.full_name)/$headRef ($headSha) -> $($pr.base.repo.full_name)/$TargetBranch" -ForegroundColor Cyan

        # Fetch base branch from the base repo.
        git remote remove _detect_base 2>$null | Out-Null
        git remote add _detect_base $baseRepoCloneUrl
        git fetch _detect_base "$TargetBranch" --no-tags --prune --depth=200 | Out-Null
        git update-ref refs/remotes/origin/$TargetBranch _detect_base/$TargetBranch | Out-Null

        # Fetch head commit (works for forks too) and check it out so the diff reflects the PR changes.
        git remote remove _detect_head 2>$null | Out-Null
        git remote add _detect_head $headRepoCloneUrl
        git fetch _detect_head "$headSha" --no-tags --depth=200 | Out-Null
        git checkout --quiet $headSha | Out-Null
    } catch {
        Write-Host "##[warning]Manual PR test setup failed: $($_.Exception.Message). Falling back to running ALL categories."
        return
    }
}

# Escape hatch: PR label "run-all-uitests" forces the full category matrix to run.
if (-not [string]::IsNullOrWhiteSpace($prNumberForLookup)) {
    try {
        $labelsUrl = "https://api.github.com/repos/$repoName/issues/$prNumberForLookup/labels"
        Write-Host "Checking PR labels at $labelsUrl" -ForegroundColor Cyan
        $labels = Invoke-RestMethod -Uri $labelsUrl -Headers (Get-GitHubHeaders) -Method Get -TimeoutSec 30
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