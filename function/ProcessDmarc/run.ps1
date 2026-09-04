param($Timer)

# Diagnostic script - writes results to a diagnostic blob so we can read
# exactly what's happening, step by step. Replace with real script after diagnosis.

$log = [System.Text.StringBuilder]::new()
[void]$log.AppendLine("=== DMARC ProcessDmarc Diagnostics ===")
[void]$log.AppendLine("Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC")
[void]$log.AppendLine("")

# Step 1: Environment
[void]$log.AppendLine("--- Step 1: Environment ---")
[void]$log.AppendLine("STORAGE_ACCOUNT: $($env:STORAGE_ACCOUNT)")
[void]$log.AppendLine("RAW_CONTAINER: $($env:RAW_CONTAINER)")
[void]$log.AppendLine("DASHBOARD_CONTAINER: $($env:DASHBOARD_CONTAINER)")
[void]$log.AppendLine("PSModulePath: $($env:PSModulePath)")
[void]$log.AppendLine("PowerShell version: $($PSVersionTable.PSVersion)")
[void]$log.AppendLine("")

# Step 2: Module availability
[void]$log.AppendLine("--- Step 2: Module availability ---")
try {
    $mods = Get-Module -ListAvailable Az.Accounts, Az.Storage | Select-Object Name, Version, ModuleBase
    foreach ($m in $mods) {
        [void]$log.AppendLine("Found: $($m.Name) v$($m.Version) at $($m.ModuleBase)")
    }
    if (-not $mods) {
        [void]$log.AppendLine("NO Az modules found in any module path")
        
        $modulesPath = Join-Path $PSScriptRoot '..' 'Modules'
        if (Test-Path $modulesPath) {
            [void]$log.AppendLine("Contents of $modulesPath :")
            Get-ChildItem $modulesPath -Directory | ForEach-Object {
                [void]$log.AppendLine("  - $($_.Name)")
            }
        } else {
            [void]$log.AppendLine("Modules folder does not exist at: $modulesPath")
        }
        
        $mdPath = 'D:\home\data\ManagedDependencies'
        if (Test-Path $mdPath) {
            [void]$log.AppendLine("ManagedDependencies folder exists:")
            Get-ChildItem $mdPath -Directory -Recurse -Depth 2 | ForEach-Object {
                [void]$log.AppendLine("  $($_.FullName)")
            }
        } else {
            [void]$log.AppendLine("ManagedDependencies folder does NOT exist at: $mdPath")
        }
    }
} catch {
    [void]$log.AppendLine("ERROR listing modules: $_")
}
[void]$log.AppendLine("")

# Step 3: Try importing modules
[void]$log.AppendLine("--- Step 3: Import modules ---")
$modulesLoaded = $false
try {
    Import-Module Az.Accounts -ErrorAction Stop
    [void]$log.AppendLine("Az.Accounts imported OK")
    Import-Module Az.Storage -ErrorAction Stop
    [void]$log.AppendLine("Az.Storage imported OK")
    $modulesLoaded = $true
} catch {
    [void]$log.AppendLine("IMPORT FAILED: $_")
    [void]$log.AppendLine("Exception type: $($_.Exception.GetType().FullName)")
    if ($_.Exception.InnerException) {
        [void]$log.AppendLine("Inner exception: $($_.Exception.InnerException.Message)")
    }
}
[void]$log.AppendLine("")

# Step 4: Try connecting with MI
[void]$log.AppendLine("--- Step 4: Managed Identity connect ---")
if ($modulesLoaded) {
    try {
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
        [void]$log.AppendLine("Connected to Azure via MI OK")
    } catch {
        [void]$log.AppendLine("MI CONNECT FAILED: $_")
    }
} else {
    [void]$log.AppendLine("SKIPPED - modules not loaded")
}
[void]$log.AppendLine("")

# Step 5: Try listing blobs
[void]$log.AppendLine("--- Step 5: Blob listing ---")
if ($modulesLoaded) {
    try {
        $ctx = New-AzStorageContext -StorageAccountName $env:STORAGE_ACCOUNT -UseConnectedAccount
        [void]$log.AppendLine("Storage context created OK")
        
        $raw = @(Get-AzStorageBlob -Container 'raw' -Context $ctx -ErrorAction Stop)
        [void]$log.AppendLine("Raw blobs: $($raw.Count)")
        foreach ($b in $raw | Select-Object -First 3) {
            [void]$log.AppendLine("  - $($b.Name)")
        }
        
        $archive = @(Get-AzStorageBlob -Container 'archive' -Context $ctx -ErrorAction Stop)
        [void]$log.AppendLine("Archive blobs: $($archive.Count)")
    } catch {
        [void]$log.AppendLine("BLOB LISTING FAILED: $_")
    }
} else {
    [void]$log.AppendLine("SKIPPED - modules not loaded")
}

# Write diagnostics
[void]$log.AppendLine("")
[void]$log.AppendLine("=== END DIAGNOSTICS ===")

$diagText = $log.ToString()
Write-Host $diagText

# Write to blob via connection string (always available, no module dependency)
try {
    $connStr = $env:AzureWebJobsStorage
    if ($connStr) {
        $storCtx = New-Object Microsoft.WindowsAzure.Storage.CloudStorageAccount([Microsoft.WindowsAzure.Storage.CloudStorageAccount]::Parse($connStr))
        # Can't use SDK directly without modules - use Az module if loaded, otherwise skip blob write
    }
    if ($modulesLoaded) {
        $diagCtx = New-AzStorageContext -StorageAccountName $env:STORAGE_ACCOUNT -UseConnectedAccount
        $tmpFile = Join-Path $env:TEMP 'diagnostics.txt'
        Set-Content -LiteralPath $tmpFile -Value $diagText -Encoding UTF8
        Set-AzStorageBlobContent -File $tmpFile -Container 'dashboard' -Blob 'diagnostics.txt' `
            -Context $diagCtx -Properties @{ ContentType = 'text/plain; charset=utf-8' } -Force | Out-Null
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        Write-Host "Diagnostics written to dashboard/diagnostics.txt"
    } elseif ($connStr) {
        # Fallback: use connection string context
        $diagCtx = New-AzStorageContext -ConnectionString $connStr
        $tmpFile = Join-Path $env:TEMP 'diagnostics.txt'
        Set-Content -LiteralPath $tmpFile -Value $diagText -Encoding UTF8
        Set-AzStorageBlobContent -File $tmpFile -Container 'dashboard' -Blob 'diagnostics.txt' `
            -Context $diagCtx -Properties @{ ContentType = 'text/plain; charset=utf-8' } -Force | Out-Null
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        Write-Host "Diagnostics written to dashboard/diagnostics.txt (via conn string)"
    }
} catch {
    Write-Host "Failed to write diagnostics blob: $_"
}
