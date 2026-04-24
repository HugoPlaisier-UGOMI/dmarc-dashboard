using namespace System.Net

# HTTP-triggered function that reads the cached dashboard HTML from the private
# blob container and returns it. Authentication is handled by Easy Auth (App
# Service Authentication V2) at the platform layer when configured, *before*
# this function runs - so authLevel: anonymous in function.json is fine.

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

$storageAccount     = $env:STORAGE_ACCOUNT
$dashboardContainer = if ($env:DASHBOARD_CONTAINER) { $env:DASHBOARD_CONTAINER } else { 'dashboard' }

if (-not $storageAccount) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode  = [HttpStatusCode]::InternalServerError
        ContentType = 'text/plain; charset=utf-8'
        Body        = 'STORAGE_ACCOUNT app setting not configured.'
    })
    return
}

try {
    $ctx = New-AzStorageContext -StorageAccountName $storageAccount -UseConnectedAccount

    $tmp = Join-Path $env:TEMP ([guid]::NewGuid().ToString('N') + '.html')
    Get-AzStorageBlobContent -Container $dashboardContainer -Blob 'index.html' `
        -Context $ctx -Destination $tmp -Force -ErrorAction Stop | Out-Null

    $html = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

    # Optional: tell the caller who they are (comes from Easy Auth headers)
    $userName = $Request.Headers['X-MS-CLIENT-PRINCIPAL-NAME']
    if ($userName) {
        $html = $html -replace '</body>',
            "<div style='position:fixed;bottom:8px;right:12px;font-size:11px;color:#5b6b7d;'>Signed in as $userName</div></body>"
    }

    # ContentType MUST be a top-level property on HttpResponseContext for the
    # Functions runtime to set it correctly. Putting it in Headers does not work
    # consistently - the browser will receive text/plain and show source code.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode  = [HttpStatusCode]::OK
        ContentType = 'text/html; charset=utf-8'
        Headers     = @{ 'Cache-Control' = 'no-store, must-revalidate' }
        Body        = [string]$html
    })
}
catch {
    # Blob missing = dashboard hasn't been generated yet by ProcessDmarc
    if ($_.Exception.Message -match 'BlobNotFound|could not be found|ResourceNotFound|find blob|does not exist') {
        $placeholder = @'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>DMARC Dashboard</title>
<style>body{font-family:-apple-system,Segoe UI,sans-serif;max-width:560px;margin:80px auto;padding:24px;color:#1c2733;}
h1{font-size:22px;}p{color:#5b6b7d;line-height:1.5;}</style></head><body>
<h1>Dashboard not yet available</h1>
<p>No DMARC reports have been processed yet. The dashboard will appear here
automatically once the first aggregate report is parsed.</p>
<p>If you just set this up, send a test email with a DMARC XML attachment to
your reporting mailbox and check back in a minute.</p>
</body></html>
'@
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode  = [HttpStatusCode]::OK
            ContentType = 'text/html; charset=utf-8'
            Body        = [string]$placeholder
        })
        return
    }

    Write-Error "Dashboard fetch failed: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode  = [HttpStatusCode]::InternalServerError
        ContentType = 'text/plain; charset=utf-8'
        Body        = "Error loading dashboard: $($_.Exception.Message)"
    })
}
