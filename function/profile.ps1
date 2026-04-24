# profile.ps1 - runs once per Function host cold start

if ($env:MSI_SECRET -or $env:IDENTITY_ENDPOINT) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    try {
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
        Write-Host "Connected to Azure via managed identity."
    }
    catch {
        Write-Warning "Managed identity login failed: $_"
    }
}
