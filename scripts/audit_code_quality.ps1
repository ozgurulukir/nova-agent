<#
.SYNOPSIS
    Static Code Quality & Architecture Invariant Audit for Nova Agent.
.DESCRIPTION
    Audits adherence to:
    - INV-LEAF-1: Pure leaf module isolation (lib/ has 0 imports from src/).
    - INV-WIDGET-1: Widget decoupling (leaf widgets do not hold direct App references).
    - LOC thresholds: Flags monolithic files (>1500 LOC).
    - Error safety: Identifies catch unreachable usage across source files.
#>

[CmdletBinding()]
param(
    [string]$RootPath = "$PSScriptRoot/.."
)

$resolvedRoot = (Resolve-Path $RootPath).Path
$srcPath = Join-Path $resolvedRoot "src"
$libPath = Join-Path $resolvedRoot "lib"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " 🛡️  Nova Agent Code Quality & Invariant Auditor" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "Root Path: $resolvedRoot`n"

$violations = 0
$warnings = 0

# ----------------------------------------------------
# 1. INV-LEAF-1: lib/ Reverse Import Check
# ----------------------------------------------------
Write-Host "1. Auditing Leaf Library Isolation (INV-LEAF-1)..." -ForegroundColor Yellow
$libFiles = Get-ChildItem -Path $libPath -Filter "*.zig" -Recurse

$leafViolations = @()
foreach ($file in $libFiles) {
    $content = Get-Content $file.FullName -Raw
    if ($content -match '@import\s*\(\s*["''].*src/.*["'']\s*\)' -or 
        $content -match '@import\s*\(\s*["'']nova["'']\s*\)') {
        $leafViolations += $file.FullName
    }
}

if ($leafViolations.Count -gt 0) {
    Write-Host "  ❌ FAIL: INV-LEAF-1 violated in $($leafViolations.Count) files:" -ForegroundColor Red
    foreach ($badFile in $leafViolations) {
        Write-Host "     - $badFile" -ForegroundColor Red
    }
    $violations += $leafViolations.Count
} else {
    Write-Host "  ✅ PASS: All $($libFiles.Count) lib/ modules are pure leaves (0 reverse dependencies)." -ForegroundColor Green
}

# ----------------------------------------------------
# 2. INV-WIDGET-1: Widget App Decoupling Check
# ----------------------------------------------------
Write-Host "`n2. Auditing Leaf Widget Decoupling (INV-WIDGET-1)..." -ForegroundColor Yellow
$msgPath = Join-Path $srcPath "tui/widgets/message.zig"
$transcriptPath = Join-Path $srcPath "tui/widgets/transcript.zig"

$widgetViolations = @()

# Audit message.zig (MessageWidget)
if (Test-Path $msgPath) {
    $lines = Get-Content $msgPath
    $lineNum = 0
    foreach ($line in $lines) {
        $lineNum++
        if ($line -match 'app:\s*(\?)?\*+(const\s+)?App') {
            $widgetViolations += "$($msgPath):$($lineNum): $line"
        }
    }
}

# Audit MessageListBuilder in transcript.zig
if (Test-Path $transcriptPath) {
    $lines = Get-Content $transcriptPath
    $lineNum = 0
    $inBuilder = $false
    foreach ($line in $lines) {
        $lineNum++
        if ($line -match 'pub\s+const\s+MessageListBuilder\s*=\s*struct') {
            $inBuilder = $true
        }
        if ($inBuilder -and $line -match '^\s*app:\s*(\?)?\*+(const\s+)?App') {
            $widgetViolations += "$($transcriptPath):$($lineNum): $line"
        }
        if ($inBuilder -and $line -match '^\s*pub\s+fn\s+build') {
            $inBuilder = $false
        }
    }
}

if ($widgetViolations.Count -gt 0) {
    Write-Host "  ❌ FAIL: INV-WIDGET-1 violated:" -ForegroundColor Red
    foreach ($wv in $widgetViolations) {
        Write-Host "     - $wv" -ForegroundColor Red
    }
    $violations += $widgetViolations.Count
} else {
    Write-Host "  ✅ PASS: Leaf MessageWidget and MessageListBuilder are fully decoupled from App." -ForegroundColor Green
}

# ----------------------------------------------------
# 3. File Size & Monolithic Clusters (>1500 LOC)
# ----------------------------------------------------
Write-Host "`n3. Auditing File Size & Monolithic Clusters (>1500 LOC)..." -ForegroundColor Yellow

# Collect all first-party Zig source files across the repo (src/, lib/, tools/, bench/, build.zig)
$targetDirs = @($srcPath, $libPath, (Join-Path $resolvedRoot "tools"), (Join-Path $resolvedRoot "bench")) | Where-Object { Test-Path $_ }
$allFirstPartyZigFiles = @()
foreach ($d in $targetDirs) {
    $allFirstPartyZigFiles += Get-ChildItem -Path $d -Filter "*.zig" -Recurse
}
if (Test-Path (Join-Path $resolvedRoot "build.zig")) {
    $allFirstPartyZigFiles += Get-Item (Join-Path $resolvedRoot "build.zig")
}

$largeFiles = @()

foreach ($file in $allFirstPartyZigFiles) {
    $lineCount = (Get-Content $file.FullName | Measure-Object -Line).Lines
    if ($lineCount -gt 1500) {
        $largeFiles += [PSCustomObject]@{
            File = $file.FullName.Replace($resolvedRoot + "\", "")
            Lines = $lineCount
        }
    }
}

if ($largeFiles.Count -gt 0) {
    Write-Host "  ⚠️  WARN: $($largeFiles.Count) files exceed 1500 LOC threshold:" -ForegroundColor Yellow
    foreach ($lf in ($largeFiles | Sort-Object Lines -Descending)) {
        Write-Host "     - $($lf.Lines) lines: $($lf.File)" -ForegroundColor DarkYellow
    }
    $warnings += $largeFiles.Count
} else {
    Write-Host "  ✅ PASS: No files exceed 1500 LOC threshold." -ForegroundColor Green
}

# ----------------------------------------------------
# 4. Error Handling Audit: `catch unreachable` Density
# ----------------------------------------------------
Write-Host "`n4. Auditing 'catch unreachable' usage across first-party code..." -ForegroundColor Yellow
$catchUnreachableSites = @()

foreach ($file in $allFirstPartyZigFiles) {
    $lines = Get-Content $file.FullName
    $lineNum = 0
    $inTestBlock = $false
    foreach ($line in $lines) {
        $lineNum++
        if ($line -match '^\s*test\s+"') {
            $inTestBlock = $true
        }
        if ($line -match 'catch\s+unreachable' -and -not $inTestBlock) {
            $catchUnreachableSites += [PSCustomObject]@{
                File = $file.FullName.Replace($resolvedRoot + "\", "")
                Line = $lineNum
                Content = $line.Trim()
            }
        }
    }
}

Write-Host "  ℹ️  Found $($catchUnreachableSites.Count) non-test 'catch unreachable' occurrences across $($allFirstPartyZigFiles.Count) files." -ForegroundColor Cyan
if ($catchUnreachableSites.Count -gt 25) {
    Write-Host "  ⚠️  High density of 'catch unreachable' detected across $($catchUnreachableSites.Count) locations." -ForegroundColor Yellow
    $warnings++
} else {
    Write-Host "  ✅ 'catch unreachable' usage is within acceptable safety bounds." -ForegroundColor Green
}

# ----------------------------------------------------
# 5. Format & Syntax Verification (zig fmt --check)
# ----------------------------------------------------
Write-Host "`n5. Verifying Zig Code Formatting..." -ForegroundColor Yellow
$fmtResult = & zig fmt --check ($targetDirs | ForEach-Object { $_ }) 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✅ PASS: All first-party Zig sources conform to `zig fmt`." -ForegroundColor Green
} else {
    Write-Host "  ⚠️  WARN: Some files require formatting (`zig fmt`):" -ForegroundColor Yellow
    Write-Host "     $fmtResult" -ForegroundColor DarkYellow
    $warnings++
}

# ----------------------------------------------------
# Summary
# ----------------------------------------------------
Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host " Audit Results: $violations Violations, $warnings Warnings ($($allFirstPartyZigFiles.Count) files scanned)" -ForegroundColor ($violations -eq 0 ? "Green" : "Red")
Write-Host "==================================================" -ForegroundColor Cyan

if ($violations -gt 0) {
    Write-Host "`n❌ Audit failed due to invariant violations." -ForegroundColor Red
    exit 1
} else {
    Write-Host "`n✅ All architectural invariants verified successfully across the codebase." -ForegroundColor Green
    exit 0
}
