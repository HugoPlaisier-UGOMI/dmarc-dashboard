using namespace System.IO

# Timer-triggered function. Fires every 4 hours via the schedule in function.json.
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
            '\.xml$' { $docs += [xml](Get-Content -LiteralPath $File.FullName -Raw) }
            '\.gz$' {
                $inStream = [File]::OpenRead($File.FullName)
                $gz = New-Object System.IO.Compression.GzipStream($inStream, [System.IO.Compression.CompressionMode]::Decompress)
                $reader = New-Object System.IO.StreamReader($gz)
                $docs += [xml]$reader.ReadToEnd()
                $reader.Dispose(); $gz.Dispose(); $inStream.Dispose()
            }
            '\.zip$' {
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
                $zip = [System.IO.Compression.ZipFile]::OpenRead($File.FullName)
                foreach ($e in $zip.Entries) {
                    if ($e.FullName -match '\.xml$') {
                        $s = $e.Open(); $r = New-Object System.IO.StreamReader($s)
                        $docs += [xml]$r.ReadToEnd()
                        $r.Dispose(); $s.Dispose()
                    }
                }
                $zip.Dispose()
            }
        }
    } catch { Write-Warning "Failed to parse $($File.Name): $_" }
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
            ReportOrg = $org; ReportId = $reportId; PolicyDomain = $policyDom
            Policy = $policy; Pct = $pct; BeginUtc = $begin; EndUtc = $end
            SourceIP = $sourceIp; HeaderFrom = $headerFrom; MessageCount = $count
            Disposition = $disposition; DkimAligned = $dkimEval; SpfAligned = $spfEval
            Compliant = $compliant
        }
    }
}

function Get-RDnsName {
    param([string]$Ip)
    try { [System.Net.Dns]::GetHostEntry($Ip).HostName } catch { $null }
}

#endregion

#region ---------- DNS lookups -----------------------------------------------

function Get-DomainDnsRecords {
    param([string]$Domain)
    $result = @{ Spf = $null; Dmarc = $null }
    try {
        $txtRecords = Resolve-DnsName -Name $Domain -Type TXT -ErrorAction Stop
        foreach ($r in $txtRecords) {
            $txt = if ($r.Strings) { $r.Strings -join '' } else { $r.Text }
            if ($txt -match '^v=spf1') { $result.Spf = $txt }
        }
    } catch { Write-Warning "SPF lookup failed for $Domain : $_" }
    try {
        $dmarcRecords = Resolve-DnsName -Name "_dmarc.$Domain" -Type TXT -ErrorAction Stop
        foreach ($r in $dmarcRecords) {
            $txt = if ($r.Strings) { $r.Strings -join '' } else { $r.Text }
            if ($txt -match '^v=DMARC1') { $result.Dmarc = $txt }
        }
    } catch { Write-Warning "DMARC lookup failed for $Domain : $_" }
    return $result
}

#endregion

#region ---------- Cost query ------------------------------------------------

function Get-AzureMonthlyCost {
    param([string]$ResourceGroup)
    try {
        $azCtx = Get-AzContext
        $scope = "/subscriptions/$($azCtx.Subscription.Id)/resourceGroups/$ResourceGroup"
        $body = @{
            type = 'ActualCost'; timeframe = 'MonthToDate'
            dataset = @{ granularity = 'None'; aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } } }
        } | ConvertTo-Json -Depth 5
        $resp = Invoke-AzRestMethod -Path "$scope/providers/Microsoft.CostManagement/query?api-version=2023-11-01" -Method POST -Payload $body
        if ($resp.StatusCode -ne 200) { return 'N/A' }
        $data = $resp.Content | ConvertFrom-Json
        if ($data.properties.rows -and $data.properties.rows.Count -gt 0) {
            $cost = [math]::Round($data.properties.rows[0][0], 2)
            $currency = $data.properties.rows[0][1]
            return "$currency $($cost.ToString('N2'))"
        }
        return 'EUR 0.00'
    } catch { Write-Warning "Cost query failed: $_"; return 'N/A' }
}

#endregion

#region ---------- Time bucketing --------------------------------------------

function Get-Last7DaysBuckets {
    param([object[]]$Rows)
    $todayUtc = [DateTime]::UtcNow.Date
    $buckets = @()
    for ($i = 6; $i -ge 0; $i--) {
        $dayStart = $todayUtc.AddDays(-$i); $dayEnd = $dayStart.AddDays(1)
        $compliant = 0; $failed = 0
        foreach ($row in $Rows) {
            if ($row.BeginUtc -ge $dayStart -and $row.BeginUtc -lt $dayEnd) {
                if ($row.Compliant) { $compliant += $row.MessageCount } else { $failed += $row.MessageCount }
            }
        }
        $buckets += @{
            Label = $dayStart.ToString('ddd', [System.Globalization.CultureInfo]::InvariantCulture)
            SubLabel = $dayStart.ToString('MMM d', [System.Globalization.CultureInfo]::InvariantCulture)
            Compliant = $compliant; Failed = $failed
        }
    }
    return $buckets
}

function Get-MonthBuckets {
    param([object[]]$Rows)
    $todayUtc = [DateTime]::UtcNow.Date
    $thisMonth = [DateTime]::new($todayUtc.Year, $todayUtc.Month, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $buckets = @()
    for ($i = 11; $i -ge 0; $i--) {
        $monthStart = $thisMonth.AddMonths(-$i); $monthEnd = $monthStart.AddMonths(1)
        $compliant = 0; $failed = 0
        foreach ($row in $Rows) {
            if ($row.BeginUtc -ge $monthStart -and $row.BeginUtc -lt $monthEnd) {
                if ($row.Compliant) { $compliant += $row.MessageCount } else { $failed += $row.MessageCount }
            }
        }
        $buckets += @{
            Label = $monthStart.ToString('MMM', [System.Globalization.CultureInfo]::InvariantCulture)
            SubLabel = $monthStart.ToString('yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
            Compliant = $compliant; Failed = $failed
        }
    }
    return $buckets
}

#endregion

#region ---------- Chart rendering -------------------------------------------

function New-BarChart {
    param([Parameter(Mandatory)][object[]]$Buckets, [int]$Width = 720, [int]$Height = 280)
    $mt = 30; $mb = 50; $ml = 45; $mr = 20
    $cw = $Width - $ml - $mr; $ch = $Height - $mt - $mb
    $totals = $Buckets | ForEach-Object { $_.Compliant + $_.Failed }
    $maxT = ($totals | Measure-Object -Maximum).Maximum
    if (-not $maxT -or $maxT -eq 0) { $maxT = 1 }
    $nM = [Math]::Pow(10, [Math]::Floor([Math]::Log10($maxT)))
    $aM = [Math]::Ceiling($maxT / $nM) * $nM
    $sw = $cw / $Buckets.Count; $bw = [Math]::Min(60, $sw * 0.65); $bo = ($sw - $bw) / 2

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg viewBox='0 0 $Width $Height' xmlns='http://www.w3.org/2000/svg' style='font-family:-apple-system,Segoe UI,Roboto,sans-serif;width:100%;max-width:${Width}px;display:block'>")
    for ($g = 1; $g -le 4; $g++) {
        $y = $mt + ($ch * (1 - $g / 4))
        [void]$sb.Append("<line x1='$ml' y1='$y' x2='$($ml+$cw)' y2='$y' stroke='#e6ecf4' stroke-width='1'/>")
        [void]$sb.Append("<text x='$($ml-6)' y='$($y+3)' text-anchor='end' font-size='10' fill='#5b6b7d'>$([int]($aM*$g/4))</text>")
    }
    [void]$sb.Append("<text x='$($ml-6)' y='$($mt+$ch+3)' text-anchor='end' font-size='10' fill='#5b6b7d'>0</text>")
    [void]$sb.Append("<line x1='$ml' y1='$($mt+$ch)' x2='$($ml+$cw)' y2='$($mt+$ch)' stroke='#dde3ec' stroke-width='1'/>")

    for ($i = 0; $i -lt $Buckets.Count; $i++) {
        $b = $Buckets[$i]; $total = $b.Compliant + $b.Failed; $x = $ml + ($i * $sw) + $bo
        $cH = if ($aM -gt 0) { ($b.Compliant / $aM) * $ch } else { 0 }
        $fH = if ($aM -gt 0) { ($b.Failed / $aM) * $ch } else { 0 }
        $cY = $mt + $ch - $cH; $fY = $cY - $fH
        if ($b.Compliant -gt 0) { [void]$sb.Append("<rect x='$x' y='$cY' width='$bw' height='$cH' fill='#0a7d4f'/>") }
        if ($b.Failed -gt 0) { [void]$sb.Append("<rect x='$x' y='$fY' width='$bw' height='$fH' fill='#0072B2'/>") }
        if ($total -gt 0) { [void]$sb.Append("<text x='$($x+$bw/2)' y='$($fY-5)' text-anchor='middle' font-size='11' font-weight='600' fill='#1c2733'>$total</text>") }
        [void]$sb.Append("<text x='$($x+$bw/2)' y='$($mt+$ch+16)' text-anchor='middle' font-size='11' fill='#1c2733'>$($b.Label)</text>")
        [void]$sb.Append("<text x='$($x+$bw/2)' y='$($mt+$ch+29)' text-anchor='middle' font-size='9' fill='#5b6b7d'>$($b.SubLabel)</text>")
    }
    $lx = $Width - $mr - 180; $ly = 14
    [void]$sb.Append("<rect x='$lx' y='$($ly-9)' width='11' height='11' fill='#0a7d4f'/><text x='$($lx+16)' y='$ly' font-size='11' fill='#5b6b7d'>Compliant</text>")
    [void]$sb.Append("<rect x='$($lx+92)' y='$($ly-9)' width='11' height='11' fill='#0072B2'/><text x='$($lx+108)' y='$ly' font-size='11' fill='#5b6b7d'>Non-compliant</text>")
    [void]$sb.Append("</svg>")
    return $sb.ToString()
}

function New-PieChart {
    param([Parameter(Mandatory)][object[]]$Segments, [int]$Size = 280)
    $palette = @('#0a7d4f','#1f6feb','#D55E00','#CC79A7','#F0E442','#56B4E9','#E69F00','#009E73')
    $totalAll = ($Segments | ForEach-Object { $_.Messages }) | Measure-Object -Sum | Select-Object -ExpandProperty Sum
    if (-not $totalAll -or $totalAll -eq 0) { return '' }
    $cx = $Size/2; $cy = $Size/2; $oR = ($Size/2)-10; $iR = $oR * 0.55
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg viewBox='0 0 $Size $Size' xmlns='http://www.w3.org/2000/svg' style='font-family:-apple-system,Segoe UI,Roboto,sans-serif;width:100%;max-width:${Size}px;display:block'>")
    $sA = -90; $si = 0
    foreach ($seg in $Segments) {
        $fr = $seg.Messages / $totalAll; $sw = $fr * 360
        if ($sw -lt 0.5) { $si++; continue }
        $col = $palette[$si % $palette.Count]
        $sR = $sA*[Math]::PI/180; $eR = ($sA+$sw)*[Math]::PI/180
        $la = if ($sw -gt 180) { 1 } else { 0 }
        $p = "M $($cx+$oR*[Math]::Cos($sR)) $($cy+$oR*[Math]::Sin($sR)) A $oR $oR 0 $la 1 $($cx+$oR*[Math]::Cos($eR)) $($cy+$oR*[Math]::Sin($eR)) L $($cx+$iR*[Math]::Cos($eR)) $($cy+$iR*[Math]::Sin($eR)) A $iR $iR 0 $la 0 $($cx+$iR*[Math]::Cos($sR)) $($cy+$iR*[Math]::Sin($sR)) Z"
        [void]$sb.Append("<path d='$p' fill='$col'/>")
        $sA += $sw; $si++
    }
    [void]$sb.Append("<text x='$cx' y='$($cy-6)' text-anchor='middle' font-size='22' font-weight='600' fill='#1c2733'>$totalAll</text>")
    [void]$sb.Append("<text x='$cx' y='$($cy+12)' text-anchor='middle' font-size='10' fill='#5b6b7d'>messages</text>")
    [void]$sb.Append("</svg>")
    return $sb.ToString()
}

function New-CompliancePieChart {
    param([string]$Domain, [int]$Compliant, [int]$Failed, [int]$Size = 200)
    $total = $Compliant + $Failed
    if ($total -eq 0) { return '' }
    $pct = [math]::Round(($Compliant / $total) * 100, 1)
    $cx = $Size/2; $cy = $Size/2; $oR = ($Size/2)-8; $iR = $oR * 0.6
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg viewBox='0 0 $Size $Size' xmlns='http://www.w3.org/2000/svg' style='font-family:-apple-system,Segoe UI,Roboto,sans-serif;width:100%;max-width:${Size}px;display:block'>")
    if ($Failed -eq 0) {
        [void]$sb.Append("<circle cx='$cx' cy='$cy' r='$oR' fill='#0a7d4f'/><circle cx='$cx' cy='$cy' r='$iR' fill='white'/>")
    } elseif ($Compliant -eq 0) {
        [void]$sb.Append("<circle cx='$cx' cy='$cy' r='$oR' fill='#0072B2'/><circle cx='$cx' cy='$cy' r='$iR' fill='white'/>")
    } else {
        $cA = ($Compliant/$total)*360; $sA = -90
        $sR = $sA*[Math]::PI/180; $eR = ($sA+$cA)*[Math]::PI/180; $la = if ($cA -gt 180) {1} else {0}
        $p1 = "M $($cx+$oR*[Math]::Cos($sR)) $($cy+$oR*[Math]::Sin($sR)) A $oR $oR 0 $la 1 $($cx+$oR*[Math]::Cos($eR)) $($cy+$oR*[Math]::Sin($eR)) L $($cx+$iR*[Math]::Cos($eR)) $($cy+$iR*[Math]::Sin($eR)) A $iR $iR 0 $la 0 $($cx+$iR*[Math]::Cos($sR)) $($cy+$iR*[Math]::Sin($sR)) Z"
        [void]$sb.Append("<path d='$p1' fill='#0a7d4f'/>")
        $fA = 360-$cA; $sA2 = -90+$cA; $sR2 = $sA2*[Math]::PI/180; $eR2 = ($sA2+$fA)*[Math]::PI/180; $la2 = if ($fA -gt 180) {1} else {0}
        $p2 = "M $($cx+$oR*[Math]::Cos($sR2)) $($cy+$oR*[Math]::Sin($sR2)) A $oR $oR 0 $la2 1 $($cx+$oR*[Math]::Cos($eR2)) $($cy+$oR*[Math]::Sin($eR2)) L $($cx+$iR*[Math]::Cos($eR2)) $($cy+$iR*[Math]::Sin($eR2)) A $iR $iR 0 $la2 0 $($cx+$iR*[Math]::Cos($sR2)) $($cy+$iR*[Math]::Sin($sR2)) Z"
        [void]$sb.Append("<path d='$p2' fill='#0072B2'/>")
    }
    [void]$sb.Append("<text x='$cx' y='$($cy-4)' text-anchor='middle' font-size='20' font-weight='600' fill='#1c2733'>$pct%</text>")
    [void]$sb.Append("<text x='$cx' y='$($cy+12)' text-anchor='middle' font-size='9' fill='#5b6b7d'>compliant</text>")
    [void]$sb.Append("</svg>")
    return $sb.ToString()
}

#endregion

#region ---------- HTML report -----------------------------------------------

function New-HtmlReport {
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$IpCache = @{}, [object[]]$DayBuckets = @(), [object[]]$MonthBuckets = @(),
        [object[]]$DomainSegments = @(), [object[]]$DomainCompliance = @(),
        [hashtable]$DomainDns = @{}, [string]$MonthlyCost = 'N/A'
    )

    $totalMsgs     = ($Rows | Measure-Object MessageCount -Sum).Sum
    $compliantMsgs = ($Rows | Where-Object Compliant | Measure-Object MessageCount -Sum).Sum
    $failMsgs      = $totalMsgs - $compliantMsgs
    $compliancePct = if ($totalMsgs -gt 0) { [math]::Round(($compliantMsgs / $totalMsgs) * 100, 2) } else { 0 }

    $bySource = $Rows | Group-Object SourceIP | ForEach-Object {
        $g = $_.Group; $tot = ($g | Measure-Object MessageCount -Sum).Sum
        $pass = ($g | Where-Object Compliant | Measure-Object MessageCount -Sum).Sum
        $hn = if ($IpCache.ContainsKey($_.Name)) { $IpCache[$_.Name] } else { $null }
        [pscustomobject]@{ SourceIP=$_.Name; Hostname=$hn; Messages=$tot; Compliant=$pass; Failed=$tot-$pass
            CompliancePct=if($tot){[math]::Round(($pass/$tot)*100,1)}else{0}; HeaderFroms=($g.HeaderFrom|Sort-Object -Unique) -join ', ' }
    } | Sort-Object Messages -Descending

    $byDomain = $Rows | Group-Object HeaderFrom | ForEach-Object {
        $g = $_.Group; $tot = ($g | Measure-Object MessageCount -Sum).Sum
        $pass = ($g | Where-Object Compliant | Measure-Object MessageCount -Sum).Sum
        [pscustomobject]@{ HeaderFrom=$_.Name; Messages=$tot; Compliant=$pass; Failed=$tot-$pass
            CompliancePct=if($tot){[math]::Round(($pass/$tot)*100,1)}else{0} }
    } | Sort-Object Messages -Descending

    $reporters = $Rows | Group-Object ReportOrg | ForEach-Object {
        [pscustomobject]@{ Reporter=$_.Name; Reports=($_.Group.ReportId|Sort-Object -Unique).Count
            Messages=($_.Group|Measure-Object MessageCount -Sum).Sum }
    } | Sort-Object Messages -Descending

    $failures = $Rows | Where-Object { -not $_.Compliant } | Sort-Object MessageCount -Descending | Select-Object -First 100

    $nowAmsR = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $amsZone)
    $amsLR = if ($amsZone.IsDaylightSavingTime($nowAmsR)) { 'CEST' } else { 'CET' }
    $generated = $nowAmsR.ToString('yyyy-MM-dd HH:mm') + " $amsLR"
    $rangeMin = ($Rows.BeginUtc | Sort-Object | Select-Object -First 1)
    $rangeMax = ($Rows.EndUtc | Sort-Object -Descending | Select-Object -First 1)
    $statusColor = if ($compliancePct -ge 95) { '#0a7d4f' } elseif ($compliancePct -ge 80) { '#1f6feb' } else { '#0072B2' }

    $dayChartSvg   = if ($DayBuckets.Count -gt 0) { New-BarChart -Buckets $DayBuckets } else { '' }
    $monthChartSvg = if ($MonthBuckets.Count -gt 0) { New-BarChart -Buckets $MonthBuckets } else { '' }
    $msgPieSvg     = if ($DomainSegments.Count -gt 0) { New-PieChart -Segments $DomainSegments -Size 280 } else { '' }

    # Per-domain compliance donuts
    $domainPiesHtml = ''
    foreach ($dc in $DomainCompliance) {
        $pieSvg = New-CompliancePieChart -Domain $dc.HeaderFrom -Compliant $dc.Compliant -Failed $dc.Failed -Size 200
        $domainPiesHtml += "<div class='pie-item'><div class='pie-title'>$($dc.HeaderFrom)</div>$pieSvg<div class='pie-sub'>$($dc.Compliant) compliant / $($dc.Failed) failed</div></div>"
    }

    # Legend for messages-by-domain
    $palette = @('#0a7d4f','#1f6feb','#D55E00','#CC79A7','#F0E442','#56B4E9','#E69F00','#009E73')
    $totalAll = ($DomainSegments | ForEach-Object { $_.Messages }) | Measure-Object -Sum | Select-Object -ExpandProperty Sum
    $legendHtml = ''; $si = 0
    foreach ($seg in $DomainSegments) {
        $col = $palette[$si % $palette.Count]
        $pS = if ($totalAll -gt 0) { [math]::Round(($seg.Messages/$totalAll)*100,1) } else { 0 }
        $legendHtml += "<div style='display:flex;align-items:center;gap:6px;margin-bottom:4px'><span style='display:inline-block;width:12px;height:12px;border-radius:2px;background:$col;flex-shrink:0'></span><span style='font-size:12px'><strong>$($seg.HeaderFrom)</strong> $($seg.Messages) msgs ($pS%)</span></div>"
        $si++
    }

    # Per-domain detail cards with alignment stats and DNS records
    $domainDetailHtml = ''
    foreach ($dc in $DomainCompliance) {
        $dom = $dc.HeaderFrom
        $domRows = $Rows | Where-Object { $_.HeaderFrom -eq $dom }
        $total = ($domRows | Measure-Object MessageCount -Sum).Sum
        $spfPass = ($domRows | Where-Object { $_.SpfAligned -eq 'pass' } | Measure-Object MessageCount -Sum).Sum
        $dkimPass = ($domRows | Where-Object { $_.DkimAligned -eq 'pass' } | Measure-Object MessageCount -Sum).Sum
        $dmarcPass = ($domRows | Where-Object Compliant | Measure-Object MessageCount -Sum).Sum

        $dmarcPct = if ($total -gt 0) { [math]::Round(($dmarcPass/$total)*100,1) } else { 0 }
        $spfPct   = if ($total -gt 0) { [math]::Round(($spfPass/$total)*100,1) } else { 0 }
        $dkimPct  = if ($total -gt 0) { [math]::Round(($dkimPass/$total)*100,1) } else { 0 }

        $spfRecord = if ($DomainDns.ContainsKey($dom) -and $DomainDns[$dom].Spf) { $DomainDns[$dom].Spf } else { '<em>not found</em>' }
        $dmarcRecord = if ($DomainDns.ContainsKey($dom) -and $DomainDns[$dom].Dmarc) { $DomainDns[$dom].Dmarc } else { '<em>not found</em>' }

        $dmarcBarColor = if ($dmarcPct -ge 95) { '#0a7d4f' } elseif ($dmarcPct -ge 80) { '#1f6feb' } else { '#0072B2' }
        $spfBarColor   = if ($spfPct -ge 95) { '#0a7d4f' } elseif ($spfPct -ge 80) { '#1f6feb' } else { '#0072B2' }
        $dkimBarColor  = if ($dkimPct -ge 95) { '#0a7d4f' } elseif ($dkimPct -ge 80) { '#1f6feb' } else { '#0072B2' }

        $domainDetailHtml += @"
    <div class="domain-card">
      <h3>$dom</h3>
      <div class="stat-grid">
        <div class="stat-row">
          <span class="stat-label">DMARC compliance</span>
          <span class="stat-value" style="color:$dmarcBarColor">$dmarcPct%</span>
          <div class="stat-bar"><span style="width:$dmarcPct%;background:$dmarcBarColor"></span></div>
          <span class="stat-detail">$dmarcPass / $total messages</span>
        </div>
        <div class="stat-row">
          <span class="stat-label">SPF alignment</span>
          <span class="stat-value" style="color:$spfBarColor">$spfPct%</span>
          <div class="stat-bar"><span style="width:$spfPct%;background:$spfBarColor"></span></div>
          <span class="stat-detail">$spfPass / $total messages</span>
        </div>
        <div class="stat-row">
          <span class="stat-label">DKIM alignment</span>
          <span class="stat-value" style="color:$dkimBarColor">$dkimPct%</span>
          <div class="stat-bar"><span style="width:$dkimPct%;background:$dkimBarColor"></span></div>
          <span class="stat-detail">$dkimPass / $total messages</span>
        </div>
      </div>
      <div class="dns-records">
        <div class="dns-row"><span class="dns-label">SPF record</span><code class="dns-value">$spfRecord</code></div>
        <div class="dns-row"><span class="dns-label">DMARC record</span><code class="dns-value">$dmarcRecord</code></div>
      </div>
    </div>
"@
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DMARC Compliance Dashboard</title>
<style>
  :root { --bg:#f5f7fa;--card:#ffffff;--ink:#1c2733;--muted:#5b6b7d;--border:#dde3ec;--accent:#1f6feb;--accent2:#0a7d4f;--warn:#0072B2;--row:#f0f4fa; }
  * { box-sizing:border-box; }
  body { font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;background:var(--bg);color:var(--ink);margin:0;padding:24px;max-width:1400px;margin:0 auto; }
  h1 { margin:0 0 4px 0;font-size:24px; }
  h2 { margin:28px 0 10px;font-size:16px;border-bottom:2px solid var(--border);padding-bottom:6px; }
  .sub { color:var(--muted);font-size:13px;margin-bottom:20px; }
  .cards { display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:14px;margin-bottom:8px; }
  .card { background:var(--card);border:1px solid var(--border);border-radius:10px;padding:14px 16px; }
  .card .label { font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.5px; }
  .card .value { font-size:26px;font-weight:600;margin-top:4px; }
  .pct { color:$statusColor; }
  .cost { color:var(--muted);font-size:18px; }
  .chart-card { background:var(--card);border:1px solid var(--border);border-radius:10px;padding:18px 20px;margin-top:14px; }
  .chart-card h3 { margin:0 0 8px 0;font-size:14px;color:var(--ink);font-weight:600; }
  .pie-row { display:flex;flex-wrap:wrap;gap:20px;align-items:flex-start; }
  .pie-item { text-align:center;flex:0 0 auto;min-width:200px; }
  .pie-item-main { text-align:center;flex:0 0 auto;min-width:280px; }
  .pie-title { font-size:13px;font-weight:600;color:var(--ink);margin-bottom:6px; }
  .pie-sub { font-size:11px;color:var(--muted);margin-top:4px; }
  .pie-legend { display:flex;flex-direction:column;justify-content:center;min-width:160px; }
  table { width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--border);border-radius:8px;overflow:hidden;font-size:13px; }
  th,td { text-align:left;padding:8px 10px;border-bottom:1px solid var(--border);vertical-align:top; }
  th { background:#eef2f8;font-weight:600;position:sticky;top:0;z-index:1; }
  tr:nth-child(even) td { background:var(--row); }
  td.num,th.num { text-align:right;font-variant-numeric:tabular-nums; }
  .ok { color:var(--accent2);font-weight:600; }
  .fail { color:var(--warn);font-weight:600; }
  .small { font-size:11px;color:var(--muted); }
  .ip-host { font-size:11px;color:var(--muted);margin-top:2px;word-break:break-all; }
  .bar { background:#e6ecf4;border-radius:4px;height:8px;overflow:hidden; }
  .bar > span { display:block;height:100%;background:var(--accent); }
  .scroll-table { max-height:440px;overflow-y:auto;border:1px solid var(--border);border-radius:8px; }
  .scroll-table table { border:none; }

  /* Domain detail cards */
  .domain-cards { display:grid;grid-template-columns:repeat(auto-fit,minmax(380px,1fr));gap:16px;margin-top:14px; }
  .domain-card { background:var(--card);border:1px solid var(--border);border-radius:10px;padding:18px 20px; }
  .domain-card h3 { margin:0 0 14px 0;font-size:16px;font-weight:600;color:var(--ink); }
  .stat-grid { display:flex;flex-direction:column;gap:12px;margin-bottom:16px; }
  .stat-row { display:grid;grid-template-columns:140px 60px 1fr;grid-template-rows:auto auto;gap:2px 12px;align-items:center; }
  .stat-label { font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.3px; }
  .stat-value { font-size:16px;font-weight:700;text-align:right; }
  .stat-bar { grid-column:3;background:#e6ecf4;border-radius:4px;height:10px;overflow:hidden; }
  .stat-bar > span { display:block;height:100%;border-radius:4px; }
  .stat-detail { grid-column:1/-1;font-size:11px;color:var(--muted); }
  .dns-records { border-top:1px solid var(--border);padding-top:12px;display:flex;flex-direction:column;gap:8px; }
  .dns-row { display:flex;flex-direction:column;gap:2px; }
  .dns-label { font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.3px; }
  .dns-value { font-size:12px;color:var(--ink);background:#f0f4fa;padding:6px 10px;border-radius:6px;word-break:break-all;display:block; }
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

  <div class="chart-card"><h3>Last 7 days</h3>$dayChartSvg</div>

  <div class="chart-card">
    <h3>Domain overview</h3>
    <div class="pie-row">
      <div class="pie-item-main"><div class="pie-title">Messages by domain</div>$msgPieSvg</div>
      <div class="pie-legend">$legendHtml</div>
      $domainPiesHtml
    </div>
  </div>

  <div class="chart-card"><h3>Last 12 months</h3>$monthChartSvg</div>

  <h2>Compliance by sending source (IP)</h2>
  <div class="scroll-table"><table>
    <thead><tr><th>Source IP / Hostname</th><th>Header-From domains</th><th class="num">Messages</th><th class="num">Compliant</th><th class="num">Failed</th><th class="num">Rate</th><th>Trend</th></tr></thead>
    <tbody>
"@

    foreach ($s in $bySource) {
        $bw = [int]$s.CompliancePct
        $rc = if ($s.CompliancePct -ge 95) { 'ok' } elseif ($s.CompliancePct -lt 80) { 'fail' } else { '' }
        $hn = if ($s.Hostname) { $s.Hostname } else { '<em>no rDNS</em>' }
        $html += "<tr><td><code>$($s.SourceIP)</code><div class='ip-host'>$hn</div></td><td class='small'>$($s.HeaderFroms)</td><td class='num'>$($s.Messages.ToString('N0'))</td><td class='num ok'>$($s.Compliant.ToString('N0'))</td><td class='num fail'>$($s.Failed.ToString('N0'))</td><td class='num $rc'>$($s.CompliancePct)%</td><td><div class='bar'><span style='width:$bw%'></span></div></td></tr>`n"
    }

    $html += @"
    </tbody></table></div>

  <h2>Compliance by Header-From domain</h2>
  <table><thead><tr><th>Header-From</th><th class="num">Messages</th><th class="num">Compliant</th><th class="num">Failed</th><th class="num">Rate</th></tr></thead><tbody>
"@
    foreach ($d in $byDomain) {
        $rc = if ($d.CompliancePct -ge 95) { 'ok' } elseif ($d.CompliancePct -lt 80) { 'fail' } else { '' }
        $html += "<tr><td>$($d.HeaderFrom)</td><td class='num'>$($d.Messages.ToString('N0'))</td><td class='num ok'>$($d.Compliant.ToString('N0'))</td><td class='num fail'>$($d.Failed.ToString('N0'))</td><td class='num $rc'>$($d.CompliancePct)%</td></tr>`n"
    }

    $html += @"
  </tbody></table>

  <h2>Reporting organisations</h2>
  <table><thead><tr><th>Reporter</th><th class="num">Reports</th><th class="num">Messages</th></tr></thead><tbody>
"@
    foreach ($r in $reporters) {
        $html += "<tr><td>$($r.Reporter)</td><td class='num'>$($r.Reports)</td><td class='num'>$($r.Messages.ToString('N0'))</td></tr>`n"
    }

    $html += @"
  </tbody></table>

  <h2>Top non-compliant rows (max 100)</h2>
  <table><thead><tr><th>Source IP</th><th>Header-From</th><th class="num">Messages</th><th>Disposition</th><th>DKIM (aligned)</th><th>SPF (aligned)</th><th>Reporter</th></tr></thead><tbody>
"@
    foreach ($f in $failures) {
        $hn = if ($IpCache.ContainsKey($f.SourceIP)) { $IpCache[$f.SourceIP] } else { $null }
        $hd = if ($hn) { "<div class='ip-host'>$hn</div>" } else { '' }
        $html += "<tr><td><code>$($f.SourceIP)</code>$hd</td><td>$($f.HeaderFrom)</td><td class='num'>$($f.MessageCount.ToString('N0'))</td><td>$($f.Disposition)</td><td class='fail'>$($f.DkimAligned)</td><td class='fail'>$($f.SpfAligned)</td><td class='small'>$($f.ReportOrg)</td></tr>`n"
    }

    $html += @"
  </tbody></table>

  <h2>Domain details</h2>
  <div class="domain-cards">
    $domainDetailHtml
  </div>

  <p class="small" style="margin-top:24px">
    DMARC compliance = aligned DKIM pass OR aligned SPF pass (per RFC 7489).
    Dashboard refreshes every 4 hours from DMARC aggregate reports in the shared mailbox.
  </p>
</body>
</html>
"@

    Set-Content -LiteralPath $Path -Value $html -Encoding UTF8
}

#endregion

#region ---------- Main -------------------------------------------------------

# Ensure archive container exists
try { Get-AzStorageContainer -Name $archiveContainer -Context $ctx -ErrorAction Stop | Out-Null }
catch { New-AzStorageContainer -Name $archiveContainer -Context $ctx -Permission Off | Out-Null; Write-Host "Created archive container." }

Write-Host "Scanning blobs in '$rawContainer' and '$archiveContainer' ..."
$rawBlobs     = @(Get-AzStorageBlob -Container $rawContainer     -Context $ctx -ErrorAction Stop)
$archiveBlobs = @(Get-AzStorageBlob -Container $archiveContainer -Context $ctx -ErrorAction SilentlyContinue)
$allBlobs     = $rawBlobs + $archiveBlobs
Write-Host "Found $($rawBlobs.Count) in raw, $($archiveBlobs.Count) in archive."

$allRows = New-Object System.Collections.Generic.List[object]
$processedBlobs = New-Object System.Collections.Generic.List[object]
$processed = 0; $skipped = 0

foreach ($blob in $allBlobs) {
    if ($blob.Name -notmatch '\.(xml|gz|zip)$') { $skipped++; continue }
    $isRaw = $blob.ICloudBlob.Container.Name -eq $rawContainer
    $blobContainer = if ($isRaw) { $rawContainer } else { $archiveContainer }
    $tmp = Join-Path $env:TEMP ([guid]::NewGuid().ToString('N') + [IO.Path]::GetExtension($blob.Name))
    try {
        Get-AzStorageBlobContent -Blob $blob.Name -Container $blobContainer -Context $ctx -Destination $tmp -Force | Out-Null
        $fi = Get-Item -LiteralPath $tmp
        $xmls = Expand-DmarcFile -File $fi
        $blobYear = $null
        foreach ($xml in $xmls) {
            $rows = ConvertFrom-DmarcXml -Xml $xml
            foreach ($r in $rows) { $allRows.Add($r) | Out-Null; if (-not $blobYear -and $r.BeginUtc) { $blobYear = $r.BeginUtc.Year } }
        }
        if ($isRaw) {
            if (-not $blobYear) { $blobYear = (Get-Date).ToUniversalTime().Year }
            $processedBlobs.Add(@{ Name = $blob.Name; Year = $blobYear }) | Out-Null
        }
        $processed++
    } catch { Write-Warning "Blob '$($blob.Name)' failed: $_" }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
}

Write-Host "Processed $processed blobs, skipped $skipped, parsed $($allRows.Count) record rows."
if ($allRows.Count -eq 0) { Write-Warning "No DMARC records found."; return }

# Reverse DNS
Write-Host "Resolving reverse DNS..."
$ipCache = @{}
$uniqueIps = $allRows.SourceIP | Sort-Object -Unique
foreach ($ip in $uniqueIps) { $ipCache[$ip] = Get-RDnsName $ip }
Write-Host "Resolved $(($ipCache.Values|Where-Object{$_}).Count) of $($uniqueIps.Count) IPs."

# Chart data
$rowsArray = $allRows.ToArray()
$dayBuckets   = Get-Last7DaysBuckets -Rows $rowsArray
$monthBuckets = Get-MonthBuckets     -Rows $rowsArray

$domainSegments = $rowsArray | Group-Object HeaderFrom | ForEach-Object {
    [pscustomobject]@{ HeaderFrom=$_.Name; Messages=($_.Group|Measure-Object MessageCount -Sum).Sum }
} | Sort-Object Messages -Descending

$domainCompliance = $rowsArray | Group-Object HeaderFrom | ForEach-Object {
    $g = $_.Group; $tot = ($g|Measure-Object MessageCount -Sum).Sum; $pass = ($g|Where-Object Compliant|Measure-Object MessageCount -Sum).Sum
    [pscustomobject]@{ HeaderFrom=$_.Name; Messages=$tot; Compliant=$pass; Failed=$tot-$pass }
} | Sort-Object Messages -Descending

# DNS lookups for SPF and DMARC records per domain
Write-Host "Looking up DNS records per domain..."
$domainDns = @{}
$uniqueDomains = $rowsArray.HeaderFrom | Sort-Object -Unique
foreach ($dom in $uniqueDomains) {
    $domainDns[$dom] = Get-DomainDnsRecords -Domain $dom
}
Write-Host "DNS lookups complete for $($uniqueDomains.Count) domains."

# Cost
Write-Host "Querying Azure costs..."
$monthlyCost = Get-AzureMonthlyCost -ResourceGroup 'rg-dmarc'
Write-Host "Monthly cost: $monthlyCost"

$outHtml = Join-Path $env:TEMP 'index.html'
New-HtmlReport -Rows $rowsArray -Path $outHtml -IpCache $ipCache `
    -DayBuckets $dayBuckets -MonthBuckets $monthBuckets `
    -DomainSegments $domainSegments -DomainCompliance $domainCompliance `
    -DomainDns $domainDns -MonthlyCost $monthlyCost

Set-AzStorageBlobContent -File $outHtml -Container $dashboardContainer -Blob 'index.html' `
    -Context $ctx -Properties @{ ContentType = 'text/html; charset=utf-8' } -Force | Out-Null
Remove-Item -LiteralPath $outHtml -Force -ErrorAction SilentlyContinue
Write-Host "Dashboard published."

# Archive
if ($processedBlobs.Count -gt 0) {
    Write-Host "Archiving $($processedBlobs.Count) blobs..."
    $archived = 0
    foreach ($pb in $processedBlobs) {
        $destName = "$($pb.Year)/$($pb.Name)"
        try {
            Start-AzStorageBlobCopy -SrcContainer $rawContainer -SrcBlob $pb.Name -DestContainer $archiveContainer -DestBlob $destName -Context $ctx -Force | Out-Null
            Get-AzStorageBlobCopyState -Container $archiveContainer -Blob $destName -Context $ctx -WaitForComplete | Out-Null
            Remove-AzStorageBlob -Container $rawContainer -Blob $pb.Name -Context $ctx -Force | Out-Null
            $archived++
        } catch { Write-Warning "Failed to archive '$($pb.Name)': $_" }
    }
    Write-Host "Archived $archived of $($processedBlobs.Count) blobs."
}

#endregion
