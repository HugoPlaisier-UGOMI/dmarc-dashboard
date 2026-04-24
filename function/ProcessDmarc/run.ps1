using namespace System.IO

# Timer-triggered function. Fires hourly via the schedule in function.json.
# Re-reads every blob in raw (new) and archive (historical) containers,
# regenerates the dashboard, then moves processed raw blobs to archive/YYYY/.

param($Timer)

$ErrorActionPreference = 'Stop'

$amsZone = [TimeZoneInfo]::FindSystemTimeZoneById('W. Europe Standard Time')
$nowAms  = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $amsZone)
$amsLabel = if ($amsZone.IsDaylightSavingTime($nowAms)) { 'CEST' } else { 'CET' }

Write-Host "Timer trigger fired at $($nowAms.ToString('yyyy-MM-dd HH:mm:ss')) $amsLabel"

$storageAccount     = $env:STORAGE_ACCOUNT
$rawContainer       = if ($env:RAW_CONTAINER)       { $env:RAW_CONTAINER }       else { 'raw' }
$dashboardContainer = if ($env:DASHBOARD_CONTAINER) { $env:DASHBOARD_CONTAINER } else { 'dashboard' }
$archiveContainer   = 'archive'

if (-not $storageAccount) { throw "STORAGE_ACCOUNT app setting is not set." }

$ctx = New-AzStorageContext -StorageAccountName $storageAccount -UseConnectedAccount

#region ---------- Parser helpers --------------------------------------------

function Expand-DmarcFile {
    param([Parameter(Mandatory)][FileInfo]$File)

    $docs = @()
    try {
        switch -Regex ($File.Extension.ToLower()) {
            '\.xml$' {
                $docs += [xml](Get-Content -LiteralPath $File.FullName -Raw)
            }
            '\.gz$' {
                $inStream = [File]::OpenRead($File.FullName)
                $gz       = New-Object System.IO.Compression.GzipStream($inStream, [System.IO.Compression.CompressionMode]::Decompress)
                $reader   = New-Object System.IO.StreamReader($gz)
                $text     = $reader.ReadToEnd()
                $reader.Dispose(); $gz.Dispose(); $inStream.Dispose()
                $docs += [xml]$text
            }
            '\.zip$' {
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
                $zip = [System.IO.Compression.ZipFile]::OpenRead($File.FullName)
                foreach ($e in $zip.Entries) {
                    if ($e.FullName -match '\.xml$') {
                        $s = $e.Open()
                        $r = New-Object System.IO.StreamReader($s)
                        $docs += [xml]$r.ReadToEnd()
                        $r.Dispose(); $s.Dispose()
                    }
                }
                $zip.Dispose()
            }
        }
    } catch {
        Write-Warning "Failed to parse $($File.Name): $_"
    }
    return $docs
}

function ConvertFrom-DmarcXml {
    param([Parameter(Mandatory)][xml]$Xml)

    $fb = $Xml.feedback
    if (-not $fb) { return }

    $org       = $fb.report_metadata.org_name
    $reportId  = $fb.report_metadata.report_id
    $beginUnix = [int64]$fb.report_metadata.date_range.begin
    $endUnix   = [int64]$fb.report_metadata.date_range.end
    $begin     = [DateTimeOffset]::FromUnixTimeSeconds($beginUnix).UtcDateTime
    $end       = [DateTimeOffset]::FromUnixTimeSeconds($endUnix).UtcDateTime
    $policyDom = $fb.policy_published.domain
    $policy    = $fb.policy_published.p
    $pct       = $fb.policy_published.pct

    foreach ($rec in $fb.record) {
        $count       = [int]$rec.row.count
        $sourceIp    = $rec.row.source_ip
        $disposition = $rec.row.policy_evaluated.disposition
        $dkimEval    = $rec.row.policy_evaluated.dkim
        $spfEval     = $rec.row.policy_evaluated.spf
        $headerFrom  = $rec.identifiers.header_from
        $compliant   = ($dkimEval -eq 'pass') -or ($spfEval -eq 'pass')

        [pscustomobject]@{
            ReportOrg    = $org
            ReportId     = $reportId
            PolicyDomain = $policyDom
            Policy       = $policy
            Pct          = $pct
            BeginUtc     = $begin
            EndUtc       = $end
            SourceIP     = $sourceIp
            HeaderFrom   = $headerFrom
            MessageCount = $count
            Disposition  = $disposition
            DkimAligned  = $dkimEval
            SpfAligned   = $spfEval
            Compliant    = $compliant
        }
    }
}

function Get-RDnsName {
    param([string]$Ip)
    try {
        $entry = [System.Net.Dns]::GetHostEntry($Ip)
        return $entry.HostName
    } catch {
        return $null
    }
}

#endregion

#region ---------- Cost query ------------------------------------------------

function Get-AzureMonthlyCost {
    # Queries Azure Cost Management for the current month's actual cost on the
    # resource group. Returns a formatted string like "EUR 0.08" or "N/A".
    param([string]$ResourceGroup)

    try {
        $azCtx = Get-AzContext
        $subId = $azCtx.Subscription.Id
        $scope = "/subscriptions/$subId/resourceGroups/$ResourceGroup"

        $body = @{
            type      = 'ActualCost'
            timeframe = 'MonthToDate'
            dataset   = @{
                granularity = 'None'
                aggregation = @{
                    totalCost = @{ name = 'Cost'; function = 'Sum' }
                }
            }
        } | ConvertTo-Json -Depth 5

        $resp = Invoke-AzRestMethod -Path "$scope/providers/Microsoft.CostManagement/query?api-version=2023-11-01" `
            -Method POST -Payload $body

        if ($resp.StatusCode -ne 200) {
            Write-Warning "Cost API returned $($resp.StatusCode)"
            return 'N/A'
        }

        $data = $resp.Content | ConvertFrom-Json
        if ($data.properties.rows -and $data.properties.rows.Count -gt 0) {
            $cost     = [math]::Round($data.properties.rows[0][0], 2)
            $currency = $data.properties.rows[0][1]
            return "$currency $($cost.ToString('N2'))"
        }
        return 'EUR 0.00'
    } catch {
        Write-Warning "Cost query failed: $_"
        return 'N/A'
    }
}

#endregion

#region ---------- Time bucketing for charts ---------------------------------

function Get-Last7DaysBuckets {
    # Returns 7 buckets for the last 7 days (today minus 6 through today).
    param([object[]]$Rows)

    $todayUtc = [DateTime]::UtcNow.Date
    $buckets = @()

    for ($i = 6; $i -ge 0; $i--) {
        $dayStart = $todayUtc.AddDays(-$i)
        $dayEnd   = $dayStart.AddDays(1)

        $compliant = 0
        $failed    = 0
        foreach ($row in $Rows) {
            if ($row.BeginUtc -ge $dayStart -and $row.BeginUtc -lt $dayEnd) {
                if ($row.Compliant) { $compliant += $row.MessageCount }
                else                { $failed    += $row.MessageCount }
            }
        }

        $buckets += @{
            Label     = $dayStart.ToString('ddd', [System.Globalization.CultureInfo]::InvariantCulture)
            SubLabel  = $dayStart.ToString('MMM d', [System.Globalization.CultureInfo]::InvariantCulture)
            Compliant = $compliant
            Failed    = $failed
        }
    }
    return $buckets
}

function Get-MonthBuckets {
    # Returns 12 buckets, the last 12 months ending with the current month.
    param([object[]]$Rows)

    $todayUtc = [DateTime]::UtcNow.Date
    $thisMonth = [DateTime]::new($todayUtc.Year, $todayUtc.Month, 1, 0, 0, 0, [DateTimeKind]::Utc)

    $buckets = @()
    for ($i = 11; $i -ge 0; $i--) {
        $monthStart = $thisMonth.AddMonths(-$i)
        $monthEnd   = $monthStart.AddMonths(1)

        $compliant = 0
        $failed    = 0
        foreach ($row in $Rows) {
            if ($row.BeginUtc -ge $monthStart -and $row.BeginUtc -lt $monthEnd) {
                if ($row.Compliant) { $compliant += $row.MessageCount }
                else                { $failed    += $row.MessageCount }
            }
        }

        $buckets += @{
            Label     = $monthStart.ToString('MMM', [System.Globalization.CultureInfo]::InvariantCulture)
            SubLabel  = $monthStart.ToString('yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
            Compliant = $compliant
            Failed    = $failed
        }
    }
    return $buckets
}

#endregion

#region ---------- Chart rendering -------------------------------------------

function New-BarChart {
    param(
        [Parameter(Mandatory)][object[]]$Buckets,
        [int]$Width  = 720,
        [int]$Height = 280
    )

    $marginTop    = 30
    $marginBottom = 50
    $marginLeft   = 45
    $marginRight  = 20

    $chartWidth  = $Width  - $marginLeft - $marginRight
    $chartHeight = $Height - $marginTop  - $marginBottom

    $totals  = $Buckets | ForEach-Object { $_.Compliant + $_.Failed }
    $maxTotal = ($totals | Measure-Object -Maximum).Maximum
    if (-not $maxTotal -or $maxTotal -eq 0) { $maxTotal = 1 }

    $niceMax = [Math]::Pow(10, [Math]::Floor([Math]::Log10($maxTotal)))
    $axisMax = [Math]::Ceiling($maxTotal / $niceMax) * $niceMax

    $slotWidth = $chartWidth / $Buckets.Count
    $barWidth  = [Math]::Min(60, $slotWidth * 0.65)
    $barOffset = ($slotWidth - $barWidth) / 2

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg viewBox='0 0 $Width $Height' xmlns='http://www.w3.org/2000/svg' style='font-family:-apple-system,Segoe UI,Roboto,sans-serif;width:100%;max-width:${Width}px;display:block'>")

    for ($g = 1; $g -le 4; $g++) {
        $y = $marginTop + ($chartHeight * (1 - $g / 4))
        [void]$sb.Append("<line x1='$marginLeft' y1='$y' x2='$($marginLeft + $chartWidth)' y2='$y' stroke='#e6ecf4' stroke-width='1' />")
        $tickValue = [int]($axisMax * $g / 4)
        [void]$sb.Append("<text x='$($marginLeft - 6)' y='$($y + 3)' text-anchor='end' font-size='10' fill='#5b6b7d'>$tickValue</text>")
    }

    [void]$sb.Append("<text x='$($marginLeft - 6)' y='$($marginTop + $chartHeight + 3)' text-anchor='end' font-size='10' fill='#5b6b7d'>0</text>")
    [void]$sb.Append("<line x1='$marginLeft' y1='$($marginTop + $chartHeight)' x2='$($marginLeft + $chartWidth)' y2='$($marginTop + $chartHeight)' stroke='#dde3ec' stroke-width='1' />")

    for ($i = 0; $i -lt $Buckets.Count; $i++) {
        $b = $Buckets[$i]
        $total = $b.Compliant + $b.Failed
        $x = $marginLeft + ($i * $slotWidth) + $barOffset

        $compliantHeight = if ($axisMax -gt 0) { ($b.Compliant / $axisMax) * $chartHeight } else { 0 }
        $failedHeight    = if ($axisMax -gt 0) { ($b.Failed    / $axisMax) * $chartHeight } else { 0 }

        $compliantY = $marginTop + $chartHeight - $compliantHeight
        $failedY    = $compliantY - $failedHeight

        if ($b.Compliant -gt 0) {
            [void]$sb.Append("<rect x='$x' y='$compliantY' width='$barWidth' height='$compliantHeight' fill='#0a7d4f' />")
        }
        if ($b.Failed -gt 0) {
            [void]$sb.Append("<rect x='$x' y='$failedY' width='$barWidth' height='$failedHeight' fill='#0072B2' />")
        }

        if ($total -gt 0) {
            $labelX = $x + ($barWidth / 2)
            $labelY = $failedY - 5
            [void]$sb.Append("<text x='$labelX' y='$labelY' text-anchor='middle' font-size='11' font-weight='600' fill='#1c2733'>$total</text>")
        }

        $xLabelX = $x + ($barWidth / 2)
        $xLabelY1 = $marginTop + $chartHeight + 16
        $xLabelY2 = $xLabelY1 + 13
        [void]$sb.Append("<text x='$xLabelX' y='$xLabelY1' text-anchor='middle' font-size='11' fill='#1c2733'>$($b.Label)</text>")
        [void]$sb.Append("<text x='$xLabelX' y='$xLabelY2' text-anchor='middle' font-size='9' fill='#5b6b7d'>$($b.SubLabel)</text>")
    }

    $legendY = 14
    $legendX = $Width - $marginRight - 180
    [void]$sb.Append("<rect x='$legendX' y='$($legendY - 9)' width='11' height='11' fill='#0a7d4f' />")
    [void]$sb.Append("<text x='$($legendX + 16)' y='$legendY' font-size='11' fill='#5b6b7d'>Compliant</text>")
    [void]$sb.Append("<rect x='$($legendX + 92)' y='$($legendY - 9)' width='11' height='11' fill='#0072B2' />")
    [void]$sb.Append("<text x='$($legendX + 108)' y='$legendY' font-size='11' fill='#5b6b7d'>Non-compliant</text>")

    [void]$sb.Append("</svg>")
    return $sb.ToString()
}

function New-PieChart {
    # Renders a donut pie chart as inline SVG for domain compliance breakdown.
    param(
        [Parameter(Mandatory)][object[]]$Segments,  # each: Label, Compliant, Failed
        [int]$Size = 320
    )

    # Colorblind-safe palette (Wong + extended)
    $palette = @('#0a7d4f','#1f6feb','#D55E00','#CC79A7','#F0E442','#56B4E9','#E69F00','#009E73')

    $totalAll = ($Segments | ForEach-Object { $_.Messages }) | Measure-Object -Sum | Select-Object -ExpandProperty Sum
    if (-not $totalAll -or $totalAll -eq 0) { return '' }

    $cx = $Size / 2
    $cy = $Size / 2
    $outerR = ($Size / 2) - 10
    $innerR = $outerR * 0.55   # donut hole

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg viewBox='0 0 $($Size + 220) $Size' xmlns='http://www.w3.org/2000/svg' style='font-family:-apple-system,Segoe UI,Roboto,sans-serif;width:100%;max-width:$($Size + 220)px;display:block'>")

    $startAngle = -90  # start at top
    $segIdx = 0

    foreach ($seg in $Segments) {
        $fraction = $seg.Messages / $totalAll
        $sweepAngle = $fraction * 360

        if ($sweepAngle -lt 0.5) { $segIdx++; continue }  # skip tiny slices

        $color = $palette[$segIdx % $palette.Count]

        $startRad = $startAngle * [Math]::PI / 180
        $endRad   = ($startAngle + $sweepAngle) * [Math]::PI / 180

        $x1o = $cx + $outerR * [Math]::Cos($startRad)
        $y1o = $cy + $outerR * [Math]::Sin($startRad)
        $x2o = $cx + $outerR * [Math]::Cos($endRad)
        $y2o = $cy + $outerR * [Math]::Sin($endRad)

        $x1i = $cx + $innerR * [Math]::Cos($endRad)
        $y1i = $cy + $innerR * [Math]::Sin($endRad)
        $x2i = $cx + $innerR * [Math]::Cos($startRad)
        $y2i = $cy + $innerR * [Math]::Sin($startRad)

        $largeArc = if ($sweepAngle -gt 180) { 1 } else { 0 }

        $path = "M $x1o $y1o A $outerR $outerR 0 $largeArc 1 $x2o $y2o L $x1i $y1i A $innerR $innerR 0 $largeArc 0 $x2i $y2i Z"
        [void]$sb.Append("<path d='$path' fill='$color' />")

        $startAngle += $sweepAngle
        $segIdx++
    }

    # Center label: total messages
    [void]$sb.Append("<text x='$cx' y='$($cy - 6)' text-anchor='middle' font-size='24' font-weight='600' fill='#1c2733'>$totalAll</text>")
    [void]$sb.Append("<text x='$cx' y='$($cy + 14)' text-anchor='middle' font-size='11' fill='#5b6b7d'>messages</text>")

    # Legend on the right
    $legendX = $Size + 16
    $legendY = 24
    $segIdx = 0
    foreach ($seg in $Segments) {
        $color = $palette[$segIdx % $palette.Count]
        $pct = [math]::Round(($seg.Messages / $totalAll) * 100, 1)
        [void]$sb.Append("<rect x='$legendX' y='$($legendY - 10)' width='12' height='12' rx='2' fill='$color' />")
        [void]$sb.Append("<text x='$($legendX + 18)' y='$legendY' font-size='12' fill='#1c2733'>$($seg.HeaderFrom)</text>")
        [void]$sb.Append("<text x='$($legendX + 18)' y='$($legendY + 14)' font-size='10' fill='#5b6b7d'>$($seg.Messages) msgs ($pct%)</text>")
        $legendY += 36
        $segIdx++
    }

    [void]$sb.Append("</svg>")
    return $sb.ToString()
}

#endregion

#region ---------- HTML report -----------------------------------------------

function New-HtmlReport {
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$IpCache       = @{},
        [object[]]$DayBuckets     = @(),
        [object[]]$MonthBuckets   = @(),
        [object[]]$DomainSegments = @(),
        [string]$MonthlyCost      = 'N/A'
    )

    $totalMsgs     = ($Rows | Measure-Object MessageCount -Sum).Sum
    $compliantMsgs = ($Rows | Where-Object Compliant | Measure-Object MessageCount -Sum).Sum
    $failMsgs      = $totalMsgs - $compliantMsgs
    $compliancePct = if ($totalMsgs -gt 0) { [math]::Round(($compliantMsgs / $totalMsgs) * 100, 2) } else { 0 }

    $bySource = $Rows | Group-Object SourceIP | ForEach-Object {
        $g    = $_.Group
        $tot  = ($g | Measure-Object MessageCount -Sum).Sum
        $pass = ($g | Where-Object Compliant | Measure-Object MessageCount -Sum).Sum
        $hostname = if ($IpCache.ContainsKey($_.Name)) { $IpCache[$_.Name] } else { $null }
        [pscustomobject]@{
            SourceIP      = $_.Name
            Hostname      = $hostname
            Messages      = $tot
            Compliant     = $pass
            Failed        = $tot - $pass
            CompliancePct = if ($tot) { [math]::Round(($pass / $tot) * 100, 1) } else { 0 }
            HeaderFroms   = ($g.HeaderFrom | Sort-Object -Unique) -join ', '
        }
    } | Sort-Object Messages -Descending

    $byDomain = $Rows | Group-Object HeaderFrom | ForEach-Object {
        $g    = $_.Group
        $tot  = ($g | Measure-Object MessageCount -Sum).Sum
        $pass = ($g | Where-Object Compliant | Measure-Object MessageCount -Sum).Sum
        [pscustomobject]@{
            HeaderFrom    = $_.Name
            Messages      = $tot
            Compliant     = $pass
            Failed        = $tot - $pass
            CompliancePct = if ($tot) { [math]::Round(($pass / $tot) * 100, 1) } else { 0 }
        }
    } | Sort-Object Messages -Descending

    $reporters = $Rows | Group-Object ReportOrg | ForEach-Object {
        [pscustomobject]@{
            Reporter = $_.Name
            Reports  = ($_.Group.ReportId | Sort-Object -Unique).Count
            Messages = ($_.Group | Measure-Object MessageCount -Sum).Sum
        }
    } | Sort-Object Messages -Descending

    $failures = $Rows | Where-Object { -not $_.Compliant } |
        Sort-Object MessageCount -Descending | Select-Object -First 100

    $nowAmsReport = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $amsZone)
    $amsLabelReport = if ($amsZone.IsDaylightSavingTime($nowAmsReport)) { 'CEST' } else { 'CET' }
    $generated = $nowAmsReport.ToString('yyyy-MM-dd HH:mm') + " $amsLabelReport"

    $rangeMin  = ($Rows.BeginUtc | Sort-Object | Select-Object -First 1)
    $rangeMax  = ($Rows.EndUtc   | Sort-Object -Descending | Select-Object -First 1)

    $statusColor = if ($compliancePct -ge 95) { '#0a7d4f' }
                   elseif ($compliancePct -ge 80) { '#1f6feb' }
                   else { '#0072B2' }

    $dayChartSvg   = if ($DayBuckets.Count   -gt 0) { New-BarChart -Buckets $DayBuckets   -Width 720 -Height 280 } else { '' }
    $monthChartSvg = if ($MonthBuckets.Count  -gt 0) { New-BarChart -Buckets $MonthBuckets -Width 720 -Height 280 } else { '' }
    $pieChartSvg   = if ($DomainSegments.Count -gt 0) { New-PieChart -Segments $DomainSegments -Size 320 } else { '' }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DMARC Compliance Dashboard</title>
<style>
  :root {
    --bg:#f5f7fa; --card:#ffffff; --ink:#1c2733; --muted:#5b6b7d;
    --border:#dde3ec; --accent:#1f6feb; --accent2:#0a7d4f;
    --warn:#0072B2; --row:#f0f4fa;
  }
  * { box-sizing:border-box; }
  body { font-family: -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif;
         background:var(--bg); color:var(--ink); margin:0; padding:24px; max-width:1400px; margin:0 auto; }
  h1 { margin:0 0 4px 0; font-size:24px; }
  h2 { margin:28px 0 10px; font-size:16px; border-bottom:2px solid var(--border); padding-bottom:6px; }
  .sub { color:var(--muted); font-size:13px; margin-bottom:20px; }
  .cards { display:grid; grid-template-columns:repeat(auto-fit, minmax(160px, 1fr));
           gap:14px; margin-bottom:8px; }
  .card { background:var(--card); border:1px solid var(--border); border-radius:10px;
          padding:14px 16px; }
  .card .label { font-size:12px; color:var(--muted); text-transform:uppercase; letter-spacing:.5px; }
  .card .value { font-size:26px; font-weight:600; margin-top:4px; }
  .pct { color:$statusColor; }
  .cost { color:var(--muted); font-size:18px; }
  .chart-card { background:var(--card); border:1px solid var(--border); border-radius:10px;
                padding:18px 20px; margin-top:14px; }
  .chart-card h3 { margin:0 0 8px 0; font-size:14px; color:var(--ink); font-weight:600; }
  table { width:100%; border-collapse:collapse; background:var(--card);
          border:1px solid var(--border); border-radius:8px; overflow:hidden; font-size:13px; }
  th, td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--border); vertical-align:top; }
  th { background:#eef2f8; font-weight:600; position:sticky; top:0; z-index:1; }
  tr:nth-child(even) td { background:var(--row); }
  td.num, th.num { text-align:right; font-variant-numeric: tabular-nums; }
  .ok   { color:var(--accent2); font-weight:600; }
  .fail { color:var(--warn);    font-weight:600; }
  .small { font-size:11px; color:var(--muted); }
  .ip-host { font-size:11px; color:var(--muted); margin-top:2px; word-break:break-all; }
  .bar { background:#e6ecf4; border-radius:4px; height:8px; overflow:hidden; }
  .bar > span { display:block; height:100%; background:var(--accent); }
  .scroll-table { max-height:440px; overflow-y:auto; border:1px solid var(--border); border-radius:8px; }
  .scroll-table table { border:none; }
</style>
</head>
<body>
  <h1>DMARC Compliance Dashboard</h1>
  <div class="sub">
    Last updated $generated &middot;
    Range: $($rangeMin.ToString('yyyy-MM-dd')) &rarr; $($rangeMax.ToString('yyyy-MM-dd')) &middot;
    $($Rows.Count) record rows from $($reporters.Count) reporting organisations
  </div>

  <div class="cards">
    <div class="card"><div class="label">Total messages</div><div class="value">$($totalMsgs.ToString('N0'))</div></div>
    <div class="card"><div class="label">DMARC compliant</div><div class="value ok">$($compliantMsgs.ToString('N0'))</div></div>
    <div class="card"><div class="label">Non-compliant</div><div class="value fail">$($failMsgs.ToString('N0'))</div></div>
    <div class="card"><div class="label">Compliance rate</div><div class="value pct">$compliancePct%</div></div>
    <div class="card"><div class="label">Azure cost (this month)</div><div class="value cost">$MonthlyCost</div></div>
  </div>

  <div class="chart-card">
    <h3>Last 7 days</h3>
    $dayChartSvg
  </div>

  <div class="chart-card">
    <h3>Messages by domain</h3>
    $pieChartSvg
  </div>

  <div class="chart-card">
    <h3>Last 12 months</h3>
    $monthChartSvg
  </div>

  <h2>Compliance by sending source (IP)</h2>
  <div class="scroll-table">
  <table>
    <thead><tr>
      <th>Source IP / Hostname</th><th>Header-From domains</th>
      <th class="num">Messages</th><th class="num">Compliant</th>
      <th class="num">Failed</th><th class="num">Rate</th><th>Trend</th>
    </tr></thead>
    <tbody>
"@

    foreach ($s in $bySource) {
        $barWidth  = [int]$s.CompliancePct
        $rateClass = if ($s.CompliancePct -ge 95) { 'ok' } elseif ($s.CompliancePct -lt 80) { 'fail' } else { '' }
        $hostnameDisplay = if ($s.Hostname) { $s.Hostname } else { '<em>no rDNS</em>' }
        $html += @"
      <tr>
        <td>
          <code>$($s.SourceIP)</code>
          <div class="ip-host">$hostnameDisplay</div>
        </td>
        <td class="small">$($s.HeaderFroms)</td>
        <td class="num">$($s.Messages.ToString('N0'))</td>
        <td class="num ok">$($s.Compliant.ToString('N0'))</td>
        <td class="num fail">$($s.Failed.ToString('N0'))</td>
        <td class="num $rateClass">$($s.CompliancePct)%</td>
        <td><div class="bar"><span style="width:$barWidth%"></span></div></td>
      </tr>
"@
    }

    $html += @"
    </tbody>
  </table>
  </div>

  <h2>Compliance by Header-From domain</h2>
  <table>
    <thead><tr>
      <th>Header-From</th>
      <th class="num">Messages</th><th class="num">Compliant</th>
      <th class="num">Failed</th><th class="num">Rate</th>
    </tr></thead>
    <tbody>
"@
    foreach ($d in $byDomain) {
        $rateClass = if ($d.CompliancePct -ge 95) { 'ok' } elseif ($d.CompliancePct -lt 80) { 'fail' } else { '' }
        $html += @"
      <tr>
        <td>$($d.HeaderFrom)</td>
        <td class="num">$($d.Messages.ToString('N0'))</td>
        <td class="num ok">$($d.Compliant.ToString('N0'))</td>
        <td class="num fail">$($d.Failed.ToString('N0'))</td>
        <td class="num $rateClass">$($d.CompliancePct)%</td>
      </tr>
"@
    }

    $html += @"
    </tbody>
  </table>

  <h2>Reporting organisations</h2>
  <table>
    <thead><tr><th>Reporter</th><th class="num">Reports</th><th class="num">Messages</th></tr></thead>
    <tbody>
"@
    foreach ($r in $reporters) {
        $html += "      <tr><td>$($r.Reporter)</td><td class='num'>$($r.Reports)</td><td class='num'>$($r.Messages.ToString('N0'))</td></tr>`n"
    }

    $html += @"
    </tbody>
  </table>

  <h2>Top non-compliant rows (max 100)</h2>
  <table>
    <thead><tr>
      <th>Source IP</th><th>Header-From</th><th class="num">Messages</th>
      <th>Disposition</th><th>DKIM (aligned)</th><th>SPF (aligned)</th><th>Reporter</th>
    </tr></thead>
    <tbody>
"@
    foreach ($f in $failures) {
        $hostname = if ($IpCache.ContainsKey($f.SourceIP)) { $IpCache[$f.SourceIP] } else { $null }
        $hostDisplay = if ($hostname) { "<div class='ip-host'>$hostname</div>" } else { '' }
        $html += @"
      <tr>
        <td><code>$($f.SourceIP)</code>$hostDisplay</td>
        <td>$($f.HeaderFrom)</td>
        <td class="num">$($f.MessageCount.ToString('N0'))</td>
        <td>$($f.Disposition)</td>
        <td class="fail">$($f.DkimAligned)</td>
        <td class="fail">$($f.SpfAligned)</td>
        <td class="small">$($f.ReportOrg)</td>
      </tr>
"@
    }

    $html += @"
    </tbody>
  </table>

  <p class="small" style="margin-top:24px">
    DMARC compliance = aligned DKIM pass OR aligned SPF pass (per RFC 7489).
    Dashboard refreshes hourly from DMARC aggregate reports in the shared mailbox.
  </p>
</body>
</html>
"@

    Set-Content -LiteralPath $Path -Value $html -Encoding UTF8
}

#endregion

#region ---------- Main -------------------------------------------------------

# Ensure archive container exists
try {
    Get-AzStorageContainer -Name $archiveContainer -Context $ctx -ErrorAction Stop | Out-Null
} catch {
    New-AzStorageContainer -Name $archiveContainer -Context $ctx -Permission Off | Out-Null
    Write-Host "Created archive container."
}

# Scan BOTH raw (new) and archive (historical) containers
Write-Host "Scanning blobs in '$rawContainer' and '$archiveContainer' ..."
$rawBlobs     = @(Get-AzStorageBlob -Container $rawContainer     -Context $ctx -ErrorAction Stop)
$archiveBlobs = @(Get-AzStorageBlob -Container $archiveContainer -Context $ctx -ErrorAction SilentlyContinue)
$allBlobs     = $rawBlobs + $archiveBlobs

Write-Host "Found $($rawBlobs.Count) in raw, $($archiveBlobs.Count) in archive."

$allRows = New-Object System.Collections.Generic.List[object]
$processedBlobs = New-Object System.Collections.Generic.List[object]  # track raw blobs for archiving
$processed = 0
$skipped = 0

foreach ($blob in $allBlobs) {
    if ($blob.Name -notmatch '\.(xml|gz|zip)$') { $skipped++; continue }

    # Determine source container
    $isRaw = $blob.ICloudBlob.Container.Name -eq $rawContainer
    $blobContainer = if ($isRaw) { $rawContainer } else { $archiveContainer }

    $tmp = Join-Path $env:TEMP ([guid]::NewGuid().ToString('N') + [IO.Path]::GetExtension($blob.Name))
    try {
        Get-AzStorageBlobContent -Blob $blob.Name -Container $blobContainer `
            -Context $ctx -Destination $tmp -Force | Out-Null

        $fi = Get-Item -LiteralPath $tmp
        $xmls = Expand-DmarcFile -File $fi
        $blobYear = $null
        foreach ($xml in $xmls) {
            $rows = ConvertFrom-DmarcXml -Xml $xml
            foreach ($r in $rows) {
                $allRows.Add($r) | Out-Null
                if (-not $blobYear -and $r.BeginUtc) {
                    $blobYear = $r.BeginUtc.Year
                }
            }
        }
        # Only track raw blobs for archiving (archive blobs stay where they are)
        if ($isRaw) {
            if (-not $blobYear) { $blobYear = (Get-Date).ToUniversalTime().Year }
            $processedBlobs.Add(@{ Name = $blob.Name; Year = $blobYear }) | Out-Null
        }
        $processed++
    }
    catch {
        Write-Warning "Blob '$($blob.Name)' failed: $_"
    }
    finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host "Processed $processed blobs, skipped $skipped, parsed $($allRows.Count) record rows."

if ($allRows.Count -eq 0) {
    Write-Warning "No DMARC records found - nothing to publish."
    return
}

# Reverse DNS lookups for all unique source IPs.
Write-Host "Resolving reverse DNS for source IPs..."
$ipCache = @{}
$uniqueIps = $allRows.SourceIP | Sort-Object -Unique
foreach ($ip in $uniqueIps) {
    $ipCache[$ip] = Get-RDnsName $ip
}
$resolved = ($ipCache.Values | Where-Object { $_ }).Count
Write-Host "Resolved $resolved of $($uniqueIps.Count) IPs to hostnames."

# Build time-series buckets for the charts.
Write-Host "Building time-series buckets..."
$rowsArray = $allRows.ToArray()
$dayBuckets   = Get-Last7DaysBuckets -Rows $rowsArray
$monthBuckets = Get-MonthBuckets     -Rows $rowsArray

# Domain segments for the pie chart (same data as byDomain table)
$domainSegments = $rowsArray | Group-Object HeaderFrom | ForEach-Object {
    $g   = $_.Group
    $tot = ($g | Measure-Object MessageCount -Sum).Sum
    [pscustomobject]@{
        HeaderFrom = $_.Name
        Messages   = $tot
    }
} | Sort-Object Messages -Descending

# Azure cost for this month
Write-Host "Querying Azure costs..."
$monthlyCost = Get-AzureMonthlyCost -ResourceGroup 'rg-dmarc'
Write-Host "Monthly cost: $monthlyCost"

$outHtml = Join-Path $env:TEMP 'index.html'
New-HtmlReport -Rows $rowsArray -Path $outHtml -IpCache $ipCache `
    -DayBuckets $dayBuckets -MonthBuckets $monthBuckets `
    -DomainSegments $domainSegments -MonthlyCost $monthlyCost

Set-AzStorageBlobContent -File $outHtml -Container $dashboardContainer -Blob 'index.html' `
    -Context $ctx -Properties @{ ContentType = 'text/html; charset=utf-8' } -Force | Out-Null

Remove-Item -LiteralPath $outHtml -Force -ErrorAction SilentlyContinue

Write-Host "Dashboard published to $dashboardContainer/index.html"

# Archive: move successfully processed blobs from raw/ to archive/YYYY/
if ($processedBlobs.Count -gt 0) {
    Write-Host "Archiving $($processedBlobs.Count) blobs from raw ..."
    $archived = 0
    foreach ($pb in $processedBlobs) {
        $destName = "$($pb.Year)/$($pb.Name)"
        try {
            # Copy to archive container with year prefix
            Start-AzStorageBlobCopy `
                -SrcContainer $rawContainer -SrcBlob $pb.Name `
                -DestContainer $archiveContainer -DestBlob $destName `
                -Context $ctx -Force | Out-Null

            # Wait for copy to complete (should be instant for small blobs)
            Get-AzStorageBlobCopyState -Container $archiveContainer -Blob $destName `
                -Context $ctx -WaitForComplete | Out-Null

            # Delete from raw
            Remove-AzStorageBlob -Container $rawContainer -Blob $pb.Name `
                -Context $ctx -Force | Out-Null

            $archived++
        } catch {
            Write-Warning "Failed to archive '$($pb.Name)': $_"
        }
    }
    Write-Host "Archived $archived of $($processedBlobs.Count) blobs."
}

#endregion
