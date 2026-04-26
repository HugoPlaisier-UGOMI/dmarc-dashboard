using namespace System.IO
param($Timer)
$ErrorActionPreference = 'Stop'
# Force dot-decimal notation for SVG coordinate output (Dutch locale uses commas)
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
$amsZone = [TimeZoneInfo]::FindSystemTimeZoneById('W. Europe Standard Time')
$nowAms  = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $amsZone)
$amsLabel = if ($amsZone.IsDaylightSavingTime($nowAms)) { 'CEST' } else { 'CET' }
Write-Host "Timer trigger fired at $($nowAms.ToString('yyyy-MM-dd HH:mm:ss')) $amsLabel"

$storageAccount     = $env:STORAGE_ACCOUNT
$rawContainer       = if ($env:RAW_CONTAINER) { $env:RAW_CONTAINER } else { 'raw' }
$dashboardContainer = if ($env:DASHBOARD_CONTAINER) { $env:DASHBOARD_CONTAINER } else { 'dashboard' }
$archiveContainer   = 'archive'
if (-not $storageAccount) { throw "STORAGE_ACCOUNT not set." }
$ctx = New-AzStorageContext -StorageAccountName $storageAccount -UseConnectedAccount

#region --- Parsers ---
function Expand-DmarcFile {
    param([Parameter(Mandatory)][FileInfo]$File)
    $docs = @()
    try {
        switch -Regex ($File.Extension.ToLower()) {
            '\.xml$' { $docs += [xml](Get-Content -LiteralPath $File.FullName -Raw) }
            '\.gz$'  { $s=[File]::OpenRead($File.FullName); $g=New-Object System.IO.Compression.GzipStream($s,[System.IO.Compression.CompressionMode]::Decompress); $r=New-Object System.IO.StreamReader($g); $docs+=[xml]$r.ReadToEnd(); $r.Dispose();$g.Dispose();$s.Dispose() }
            '\.zip$' { Add-Type -AssemblyName System.IO.Compression.FileSystem -EA SilentlyContinue; $z=[System.IO.Compression.ZipFile]::OpenRead($File.FullName); foreach($e in $z.Entries){if($e.FullName -match '\.xml$'){$s=$e.Open();$r=New-Object System.IO.StreamReader($s);$docs+=[xml]$r.ReadToEnd();$r.Dispose();$s.Dispose()}}; $z.Dispose() }
        }
    } catch { Write-Warning "Parse failed $($File.Name): $_" }
    return $docs
}

function ConvertFrom-DmarcXml {
    param([Parameter(Mandatory)][xml]$Xml)
    $fb=$Xml.feedback; if(-not $fb){return}
    $org=$fb.report_metadata.org_name; $rid=$fb.report_metadata.report_id
    $begin=[DateTimeOffset]::FromUnixTimeSeconds([int64]$fb.report_metadata.date_range.begin).UtcDateTime
    $end=[DateTimeOffset]::FromUnixTimeSeconds([int64]$fb.report_metadata.date_range.end).UtcDateTime
    $pd=$fb.policy_published.domain; $pol=$fb.policy_published.p; $pct=$fb.policy_published.pct
    foreach($rec in $fb.record){
        $dk=$rec.row.policy_evaluated.dkim; $sp=$rec.row.policy_evaluated.spf
        [pscustomobject]@{ ReportOrg=$org;ReportId=$rid;PolicyDomain=$pd;Policy=$pol;Pct=$pct;BeginUtc=$begin;EndUtc=$end
            SourceIP=$rec.row.source_ip;HeaderFrom=$rec.identifiers.header_from;MessageCount=[int]$rec.row.count
            Disposition=$rec.row.policy_evaluated.disposition;DkimAligned=$dk;SpfAligned=$sp;Compliant=($dk-eq'pass')-or($sp-eq'pass') }
    }
}

function Get-RDnsName { param([string]$Ip); try{[System.Net.Dns]::GetHostEntry($Ip).HostName}catch{$null} }
#endregion

#region --- DNS via Google DoH ---
function Get-DomainDnsRecords {
    param([string]$Domain)
    $result = @{ Spf = $null; Dmarc = $null }
    try {
        $r = Invoke-RestMethod -Uri "https://dns.google/resolve?name=$Domain&type=TXT" -UseBasicParsing -EA Stop
        if ($r.Answer) { foreach ($a in $r.Answer) { $t=($a.data -replace '"','').Trim(); if($t -match '^v=spf1'){$result.Spf=$t;break} } }
    } catch { Write-Warning "SPF lookup failed for $Domain" }
    try {
        $r = Invoke-RestMethod -Uri "https://dns.google/resolve?name=_dmarc.$Domain&type=TXT" -UseBasicParsing -EA Stop
        if ($r.Answer) { foreach ($a in $r.Answer) { $t=($a.data -replace '"','').Trim(); if($t -match '^v=DMARC1'){$result.Dmarc=$t;break} } }
    } catch { Write-Warning "DMARC lookup failed for $Domain" }
    return $result
}
#endregion

#region --- Cost ---
function Get-AzureMonthlyCost {
    param([string]$RG)
    try {
        $scope="/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$RG"
        $body=@{type='ActualCost';timeframe='MonthToDate';dataset=@{granularity='None';aggregation=@{totalCost=@{name='Cost';function='Sum'}}}}|ConvertTo-Json -Depth 5
        $r=Invoke-AzRestMethod -Path "$scope/providers/Microsoft.CostManagement/query?api-version=2023-11-01" -Method POST -Payload $body
        if($r.StatusCode-ne200){return 'N/A'}
        $d=$r.Content|ConvertFrom-Json
        if($d.properties.rows -and $d.properties.rows.Count-gt0){$c=[math]::Round($d.properties.rows[0][0],2);return "$($d.properties.rows[0][1]) $($c.ToString('N2'))"}
        return 'EUR 0.00'
    } catch { Write-Warning "Cost query failed: $_"; return 'N/A' }
}
#endregion

#region --- Time buckets ---
function Get-Last7DaysBuckets {
    param([object[]]$Rows)
    $today=[DateTime]::UtcNow.Date; $b=@()
    for($i=6;$i-ge0;$i--){ $ds=$today.AddDays(-$i);$de=$ds.AddDays(1);$c=0;$f=0
        foreach($r in $Rows){if($r.BeginUtc-ge$ds -and $r.BeginUtc-lt$de){if($r.Compliant){$c+=$r.MessageCount}else{$f+=$r.MessageCount}}}
        $b+=@{Label=$ds.ToString('ddd',[cultureinfo]::InvariantCulture);SubLabel=$ds.ToString('MMM d',[cultureinfo]::InvariantCulture);Compliant=$c;Failed=$f}}
    return $b
}
function Get-MonthBuckets {
    param([object[]]$Rows)
    $today=[DateTime]::UtcNow.Date;$tm=[DateTime]::new($today.Year,$today.Month,1,0,0,0,[DateTimeKind]::Utc);$b=@()
    for($i=11;$i-ge0;$i--){$ms=$tm.AddMonths(-$i);$me=$ms.AddMonths(1);$c=0;$f=0
        foreach($r in $Rows){if($r.BeginUtc-ge$ms -and $r.BeginUtc-lt$me){if($r.Compliant){$c+=$r.MessageCount}else{$f+=$r.MessageCount}}}
        $b+=@{Label=$ms.ToString('MMM',[cultureinfo]::InvariantCulture);SubLabel=$ms.ToString('yyyy',[cultureinfo]::InvariantCulture);Compliant=$c;Failed=$f}}
    return $b
}
#endregion

#region --- Charts ---
function New-BarChart {
    param([Parameter(Mandatory)][object[]]$Buckets,[int]$Width=720,[int]$Height=280)
    $mt=30; $mb=50; $ml=45; $mr=20
    $cw=$Width-$ml-$mr; $ch=$Height-$mt-$mb
    $baseline=$mt+$ch

    $totals=$Buckets|ForEach-Object{$_.Compliant+$_.Failed}
    $maxT=($totals|Measure-Object -Maximum).Maximum
    if(-not $maxT -or $maxT-eq0){$maxT=4}
    $axisMax=[Math]::Ceiling($maxT/4)*4

    $slotW=[double]($cw/$Buckets.Count)
    $barW=[int][Math]::Min(60,[int]($slotW*0.65))
    $barOff=[int](($slotW-$barW)/2)

    $sb=New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg viewBox='0 0 $Width $Height' xmlns='http://www.w3.org/2000/svg' style='font-family:-apple-system,Segoe UI,Roboto,sans-serif;width:100%;max-width:${Width}px;display:block'>")

    for($g=1;$g-le4;$g++){
        $gy=[int]($baseline-$ch*$g/4)
        $tv=[int]($axisMax*$g/4)
        [void]$sb.Append("<line x1='$ml' y1='$gy' x2='$($ml+$cw)' y2='$gy' stroke='#e6ecf4' stroke-width='1'/>")
        [void]$sb.Append("<text x='$($ml-6)' y='$($gy+3)' text-anchor='end' font-size='10' fill='#5b6b7d'>$tv</text>")
    }
    [void]$sb.Append("<text x='$($ml-6)' y='$($baseline+3)' text-anchor='end' font-size='10' fill='#5b6b7d'>0</text>")
    [void]$sb.Append("<line x1='$ml' y1='$baseline' x2='$($ml+$cw)' y2='$baseline' stroke='#dde3ec' stroke-width='1'/>")

    for($i=0;$i-lt$Buckets.Count;$i++){
        $bk=$Buckets[$i]
        $comp=[int]$bk.Compliant
        $fail=[int]$bk.Failed
        $total=$comp+$fail

        $bx=[int]($ml+$i*$slotW+$barOff)
        $bcx=[int]($bx+$barW/2)

        $compH=[int]($comp*$ch/$axisMax)
        $failH=[int]($fail*$ch/$axisMax)

        $compY=$baseline-$compH
        $failY=$compY-$failH

        if($comp-gt0){[void]$sb.Append("<rect x='$bx' y='$compY' width='$barW' height='$compH' fill='#0a7d4f'/>")}
        if($fail-gt0){[void]$sb.Append("<rect x='$bx' y='$failY' width='$barW' height='$failH' fill='#0072B2'/>")}
        if($total-gt0){[void]$sb.Append("<text x='$bcx' y='$($failY-5)' text-anchor='middle' font-size='11' font-weight='600' fill='#1c2733'>$total</text>")}
        [void]$sb.Append("<text x='$bcx' y='$($baseline+16)' text-anchor='middle' font-size='11' fill='#1c2733'>$($bk.Label)</text>")
        [void]$sb.Append("<text x='$bcx' y='$($baseline+29)' text-anchor='middle' font-size='9' fill='#5b6b7d'>$($bk.SubLabel)</text>")
    }
    $lx=$Width-$mr-180
    [void]$sb.Append("<rect x='$lx' y='5' width='11' height='11' fill='#0a7d4f'/><text x='$($lx+16)' y='14' font-size='11' fill='#5b6b7d'>Compliant</text>")
    [void]$sb.Append("<rect x='$($lx+92)' y='5' width='11' height='11' fill='#0072B2'/><text x='$($lx+108)' y='14' font-size='11' fill='#5b6b7d'>Non-compliant</text>")
    [void]$sb.Append("</svg>"); return $sb.ToString()
}

function New-PieChart {
    param([Parameter(Mandatory)][object[]]$Segments,[int]$Size=280)
    $pal=@('#0a7d4f','#1f6feb','#D55E00','#CC79A7','#F0E442','#56B4E9','#E69F00','#009E73')
    $tA=($Segments|ForEach-Object{$_.Messages})|Measure-Object -Sum|Select-Object -ExpandProperty Sum
    if(-not $tA -or $tA-eq0){return ''}
    $cx=$Size/2;$cy=$Size/2;$oR=($Size/2)-10;$iR=$oR*0.55
    $sb=New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg viewBox='0 0 $Size $Size' xmlns='http://www.w3.org/2000/svg' style='font-family:-apple-system,Segoe UI,Roboto,sans-serif;width:100%;max-width:${Size}px;display:block'>")
    $sA=-90;$si=0
    foreach($seg in $Segments){
        $fr=$seg.Messages/$tA;$sw=$fr*360;if($sw-lt0.5){$si++;continue}
        $col=$pal[$si%$pal.Count];$sR=$sA*[Math]::PI/180;$eR=($sA+$sw)*[Math]::PI/180;$la=if($sw-gt180){1}else{0}
        $p="M $($cx+$oR*[Math]::Cos($sR)) $($cy+$oR*[Math]::Sin($sR)) A $oR $oR 0 $la 1 $($cx+$oR*[Math]::Cos($eR)) $($cy+$oR*[Math]::Sin($eR)) L $($cx+$iR*[Math]::Cos($eR)) $($cy+$iR*[Math]::Sin($eR)) A $iR $iR 0 $la 0 $($cx+$iR*[Math]::Cos($sR)) $($cy+$iR*[Math]::Sin($sR)) Z"
        [void]$sb.Append("<path d='$p' fill='$col'/>");$sA+=$sw;$si++
    }
    [void]$sb.Append("<text x='$cx' y='$($cy-6)' text-anchor='middle' font-size='22' font-weight='600' fill='#1c2733'>$tA</text>")
    [void]$sb.Append("<text x='$cx' y='$($cy+12)' text-anchor='middle' font-size='10' fill='#5b6b7d'>messages</text></svg>")
    return $sb.ToString()
}

function New-CompliancePieChart {
    param([int]$Compliant,[int]$Failed,[int]$Size=200)
    $total=$Compliant+$Failed; if($total-eq0){return ''}
    $pct=[math]::Round(($Compliant/$total)*100,1)
    $cx=$Size/2;$cy=$Size/2;$oR=($Size/2)-8;$iR=$oR*0.6
    $sb=New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg viewBox='0 0 $Size $Size' xmlns='http://www.w3.org/2000/svg' style='font-family:-apple-system,Segoe UI,Roboto,sans-serif;width:100%;max-width:${Size}px;display:block'>")
    if($Failed-eq0){ [void]$sb.Append("<circle cx='$cx' cy='$cy' r='$oR' fill='#0a7d4f'/><circle cx='$cx' cy='$cy' r='$iR' fill='white'/>") }
    elseif($Compliant-eq0){ [void]$sb.Append("<circle cx='$cx' cy='$cy' r='$oR' fill='#0072B2'/><circle cx='$cx' cy='$cy' r='$iR' fill='white'/>") }
    else {
        $cA=($Compliant/$total)*360;$sA=-90
        $sR=$sA*[Math]::PI/180;$eR=($sA+$cA)*[Math]::PI/180;$la=if($cA-gt180){1}else{0}
        $p1="M $($cx+$oR*[Math]::Cos($sR)) $($cy+$oR*[Math]::Sin($sR)) A $oR $oR 0 $la 1 $($cx+$oR*[Math]::Cos($eR)) $($cy+$oR*[Math]::Sin($eR)) L $($cx+$iR*[Math]::Cos($eR)) $($cy+$iR*[Math]::Sin($eR)) A $iR $iR 0 $la 0 $($cx+$iR*[Math]::Cos($sR)) $($cy+$iR*[Math]::Sin($sR)) Z"
        [void]$sb.Append("<path d='$p1' fill='#0a7d4f'/>")
        $fA=360-$cA;$sA2=-90+$cA;$sR2=$sA2*[Math]::PI/180;$eR2=($sA2+$fA)*[Math]::PI/180;$la2=if($fA-gt180){1}else{0}
        $p2="M $($cx+$oR*[Math]::Cos($sR2)) $($cy+$oR*[Math]::Sin($sR2)) A $oR $oR 0 $la2 1 $($cx+$oR*[Math]::Cos($eR2)) $($cy+$oR*[Math]::Sin($eR2)) L $($cx+$iR*[Math]::Cos($eR2)) $($cy+$iR*[Math]::Sin($eR2)) A $iR $iR 0 $la2 0 $($cx+$iR*[Math]::Cos($sR2)) $($cy+$iR*[Math]::Sin($sR2)) Z"
        [void]$sb.Append("<path d='$p2' fill='#0072B2'/>")
    }
    [void]$sb.Append("<text x='$cx' y='$($cy-4)' text-anchor='middle' font-size='20' font-weight='600' fill='#1c2733'>$pct%</text>")
    [void]$sb.Append("<text x='$cx' y='$($cy+12)' text-anchor='middle' font-size='9' fill='#5b6b7d'>compliant</text></svg>")
    return $sb.ToString()
}
#endregion

#region --- HTML report ---
function New-HtmlReport {
    param([Parameter(Mandatory)][object[]]$Rows,[Parameter(Mandatory)][string]$Path,
        [hashtable]$IpCache=@{},[object[]]$DayBuckets=@(),[object[]]$MonthBuckets=@(),
        [object[]]$DomainSegments=@(),[object[]]$DomainCompliance=@(),[hashtable]$DomainDns=@{},[string]$MonthlyCost='N/A')

    $totalMsgs=($Rows|Measure-Object MessageCount -Sum).Sum
    $compliantMsgs=($Rows|Where-Object Compliant|Measure-Object MessageCount -Sum).Sum
    $failMsgs=$totalMsgs-$compliantMsgs
    $compliancePct=if($totalMsgs-gt0){[math]::Round(($compliantMsgs/$totalMsgs)*100,2)}else{0}

    $bySource=$Rows|Group-Object SourceIP|ForEach-Object{$g=$_.Group;$tot=($g|Measure-Object MessageCount -Sum).Sum;$pass=($g|Where-Object Compliant|Measure-Object MessageCount -Sum).Sum
        $hn=if($IpCache.ContainsKey($_.Name)){$IpCache[$_.Name]}else{$null}
        [pscustomobject]@{SourceIP=$_.Name;Hostname=$hn;Messages=$tot;Compliant=$pass;Failed=$tot-$pass;CompliancePct=if($tot){[math]::Round(($pass/$tot)*100,1)}else{0};HeaderFroms=($g.HeaderFrom|Sort-Object -Unique)-join', '}}|Sort-Object Messages -Descending

    $byDomain=$Rows|Group-Object HeaderFrom|ForEach-Object{$g=$_.Group;$tot=($g|Measure-Object MessageCount -Sum).Sum;$pass=($g|Where-Object Compliant|Measure-Object MessageCount -Sum).Sum
        [pscustomobject]@{HeaderFrom=$_.Name;Messages=$tot;Compliant=$pass;Failed=$tot-$pass;CompliancePct=if($tot){[math]::Round(($pass/$tot)*100,1)}else{0}}}|Sort-Object Messages -Descending

    $reporters=$Rows|Group-Object ReportOrg|ForEach-Object{[pscustomobject]@{Reporter=$_.Name;Reports=($_.Group.ReportId|Sort-Object -Unique).Count;Messages=($_.Group|Measure-Object MessageCount -Sum).Sum}}|Sort-Object Messages -Descending
    $failures=$Rows|Where-Object{-not $_.Compliant}|Sort-Object MessageCount -Descending|Select-Object -First 100

    $nowR=[TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow,$amsZone)
    $alR=if($amsZone.IsDaylightSavingTime($nowR)){'CEST'}else{'CET'}
    $generated=$nowR.ToString('yyyy-MM-dd HH:mm')+" $alR"
    $rangeMin=($Rows.BeginUtc|Sort-Object|Select-Object -First 1)
    $rangeMax=($Rows.EndUtc|Sort-Object -Descending|Select-Object -First 1)
    $statusColor=if($compliancePct-ge95){'#0a7d4f'}elseif($compliancePct-ge80){'#1f6feb'}else{'#0072B2'}

    $dayChart=if($DayBuckets.Count-gt0){New-BarChart -Buckets $DayBuckets}else{''}
    $monthChart=if($MonthBuckets.Count-gt0){New-BarChart -Buckets $MonthBuckets}else{''}
    $msgPie=if($DomainSegments.Count-gt0){New-PieChart -Segments $DomainSegments -Size 280}else{''}

    # Per-domain compliance donuts
    $dpHtml=''; foreach($dc in $DomainCompliance){$ps=New-CompliancePieChart -Compliant $dc.Compliant -Failed $dc.Failed -Size 200
        $dpHtml+="<div class='pie-item'><div class='pie-title'>$($dc.HeaderFrom)</div>$ps<div class='pie-sub'>$($dc.Compliant) compliant / $($dc.Failed) failed</div></div>"}

    # Legend
    $pal=@('#0a7d4f','#1f6feb','#D55E00','#CC79A7','#F0E442','#56B4E9','#E69F00','#009E73')
    $tAll=($DomainSegments|ForEach-Object{$_.Messages})|Measure-Object -Sum|Select-Object -ExpandProperty Sum
    $legHtml='';$si=0; foreach($seg in $DomainSegments){$col=$pal[$si%$pal.Count];$pS=if($tAll-gt0){[math]::Round(($seg.Messages/$tAll)*100,1)}else{0}
        $legHtml+="<div style='display:flex;align-items:center;gap:6px;margin-bottom:4px'><span style='display:inline-block;width:12px;height:12px;border-radius:2px;background:$col;flex-shrink:0'></span><span style='font-size:12px'><strong>$($seg.HeaderFrom)</strong> $($seg.Messages) msgs ($pS%)</span></div>";$si++}

    # Domain detail cards
    $ddHtml=''
    foreach($dc in $DomainCompliance){
        $dom=$dc.HeaderFrom; $domRows=$Rows|Where-Object{$_.HeaderFrom-eq$dom}
        $total=($domRows|Measure-Object MessageCount -Sum).Sum
        $spfP=($domRows|Where-Object{$_.SpfAligned-eq'pass'}|Measure-Object MessageCount -Sum).Sum
        $dkimP=($domRows|Where-Object{$_.DkimAligned-eq'pass'}|Measure-Object MessageCount -Sum).Sum
        $dmarcP=($domRows|Where-Object Compliant|Measure-Object MessageCount -Sum).Sum
        $dmPct=if($total-gt0){[math]::Round(($dmarcP/$total)*100,1)}else{0}
        $spPct=if($total-gt0){[math]::Round(($spfP/$total)*100,1)}else{0}
        $dkPct=if($total-gt0){[math]::Round(($dkimP/$total)*100,1)}else{0}
        $spfRec=if($DomainDns.ContainsKey($dom)-and$DomainDns[$dom].Spf){$DomainDns[$dom].Spf}else{'<em>not found</em>'}
        $dmarcRec=if($DomainDns.ContainsKey($dom)-and$DomainDns[$dom].Dmarc){$DomainDns[$dom].Dmarc}else{'<em>not found</em>'}
        $c1=if($dmPct-ge95){'#0a7d4f'}elseif($dmPct-ge80){'#1f6feb'}else{'#0072B2'}
        $c2=if($spPct-ge95){'#0a7d4f'}elseif($spPct-ge80){'#1f6feb'}else{'#0072B2'}
        $c3=if($dkPct-ge95){'#0a7d4f'}elseif($dkPct-ge80){'#1f6feb'}else{'#0072B2'}
        $ddHtml+=@"
<div class="domain-card"><h3>$dom</h3><div class="stat-grid">
<div class="stat-row"><span class="stat-label">DMARC compliance</span><span class="stat-value" style="color:$c1">$dmPct%</span><div class="stat-bar"><span style="width:$dmPct%;background:$c1"></span></div><span class="stat-detail">$dmarcP / $total messages</span></div>
<div class="stat-row"><span class="stat-label">SPF alignment</span><span class="stat-value" style="color:$c2">$spPct%</span><div class="stat-bar"><span style="width:$spPct%;background:$c2"></span></div><span class="stat-detail">$spfP / $total messages</span></div>
<div class="stat-row"><span class="stat-label">DKIM alignment</span><span class="stat-value" style="color:$c3">$dkPct%</span><div class="stat-bar"><span style="width:$dkPct%;background:$c3"></span></div><span class="stat-detail">$dkimP / $total messages</span></div>
</div><div class="dns-records">
<div class="dns-row"><span class="dns-label">SPF record</span><code class="dns-value">$spfRec</code></div>
<div class="dns-row"><span class="dns-label">DMARC record</span><code class="dns-value">$dmarcRec</code></div>
</div></div>
"@
    }

    $html=@"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>DMARC Compliance Dashboard</title>
<style>
:root{--bg:#f5f7fa;--card:#fff;--ink:#1c2733;--muted:#5b6b7d;--border:#dde3ec;--accent:#1f6feb;--accent2:#0a7d4f;--warn:#0072B2;--row:#f0f4fa}
*{box-sizing:border-box}
body{font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;background:var(--bg);color:var(--ink);margin:0;padding:24px;max-width:1400px;margin:0 auto}
h1{margin:0 0 4px;font-size:24px}h2{margin:28px 0 10px;font-size:16px;border-bottom:2px solid var(--border);padding-bottom:6px}
.sub{color:var(--muted);font-size:13px;margin-bottom:20px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:14px;margin-bottom:8px}
.card{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:14px 16px}
.card .label{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.5px}
.card .value{font-size:26px;font-weight:600;margin-top:4px}.pct{color:$statusColor}.cost{color:var(--muted);font-size:18px}
.chart-card{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:18px 20px;margin-top:14px}
.chart-card h3{margin:0 0 8px;font-size:14px;font-weight:600}
.pie-row{display:flex;flex-wrap:wrap;gap:20px;align-items:flex-start}
.pie-item{text-align:center;flex:0 0 auto;min-width:200px}.pie-item-main{text-align:center;flex:0 0 auto;min-width:280px}
.pie-title{font-size:13px;font-weight:600;margin-bottom:6px}.pie-sub{font-size:11px;color:var(--muted);margin-top:4px}
.pie-legend{display:flex;flex-direction:column;justify-content:center;min-width:160px}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--border);border-radius:8px;overflow:hidden;font-size:13px}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--border);vertical-align:top}
th{background:#eef2f8;font-weight:600;position:sticky;top:0;z-index:1}
tr:nth-child(even) td{background:var(--row)}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
.ok{color:var(--accent2);font-weight:600}.fail{color:var(--warn);font-weight:600}
.small{font-size:11px;color:var(--muted)}.ip-host{font-size:11px;color:var(--muted);margin-top:2px;word-break:break-all}
.bar{background:#e6ecf4;border-radius:4px;height:8px;overflow:hidden}.bar>span{display:block;height:100%;background:var(--accent)}
.scroll-table{max-height:440px;overflow-y:auto;border:1px solid var(--border);border-radius:8px}.scroll-table table{border:none}
.domain-cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(380px,1fr));gap:16px;margin-top:14px}
.domain-card{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:18px 20px}
.domain-card h3{margin:0 0 14px;font-size:16px;font-weight:600}
.stat-grid{display:flex;flex-direction:column;gap:12px;margin-bottom:16px}
.stat-row{display:grid;grid-template-columns:140px 60px 1fr;grid-template-rows:auto auto;gap:2px 12px;align-items:center}
.stat-label{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.3px}
.stat-value{font-size:16px;font-weight:700;text-align:right}
.stat-bar{grid-column:3;background:#e6ecf4;border-radius:4px;height:10px;overflow:hidden}.stat-bar>span{display:block;height:100%;border-radius:4px}
.stat-detail{grid-column:1/-1;font-size:11px;color:var(--muted)}
.dns-records{border-top:1px solid var(--border);padding-top:12px;display:flex;flex-direction:column;gap:8px}
.dns-row{display:flex;flex-direction:column;gap:2px}
.dns-label{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.3px}
.dns-value{font-size:12px;color:var(--ink);background:#f0f4fa;padding:6px 10px;border-radius:6px;word-break:break-all;display:block}
</style></head><body>
<h1>DMARC Compliance Dashboard</h1>
<div class="sub">Last updated $generated &middot; Range: $($rangeMin.ToString('yyyy-MM-dd')) &rarr; $($rangeMax.ToString('yyyy-MM-dd')) &middot; $($Rows.Count) record rows from $($reporters.Count) reporting organisations</div>
<div class="cards">
<div class="card"><div class="label">Total messages</div><div class="value">$($totalMsgs.ToString('N0'))</div></div>
<div class="card"><div class="label">DMARC compliant</div><div class="value ok">$($compliantMsgs.ToString('N0'))</div></div>
<div class="card"><div class="label">Non-compliant</div><div class="value fail">$($failMsgs.ToString('N0'))</div></div>
<div class="card"><div class="label">Compliance rate</div><div class="value pct">$compliancePct%</div></div>
<div class="card"><div class="label">Azure cost (this month)</div><div class="value cost">$MonthlyCost</div></div>
</div>
<div class="chart-card"><h3>Last 7 days</h3>$dayChart</div>
<div class="chart-card"><h3>Domain overview</h3><div class="pie-row"><div class="pie-item-main"><div class="pie-title">Messages by domain</div>$msgPie</div><div class="pie-legend">$legHtml</div>$dpHtml</div></div>
<div class="chart-card"><h3>Last 12 months</h3>$monthChart</div>
<h2>Compliance by sending source (IP)</h2><div class="scroll-table"><table>
<thead><tr><th>Source IP / Hostname</th><th>Header-From domains</th><th class="num">Messages</th><th class="num">Compliant</th><th class="num">Failed</th><th class="num">Rate</th><th>Trend</th></tr></thead><tbody>
"@
    foreach($s in $bySource){$bw=[int]$s.CompliancePct;$rc=if($s.CompliancePct-ge95){'ok'}elseif($s.CompliancePct-lt80){'fail'}else{''};$hn=if($s.Hostname){$s.Hostname}else{'<em>no rDNS</em>'}
        $html+="<tr><td><code>$($s.SourceIP)</code><div class='ip-host'>$hn</div></td><td class='small'>$($s.HeaderFroms)</td><td class='num'>$($s.Messages.ToString('N0'))</td><td class='num ok'>$($s.Compliant.ToString('N0'))</td><td class='num fail'>$($s.Failed.ToString('N0'))</td><td class='num $rc'>$($s.CompliancePct)%</td><td><div class='bar'><span style='width:$bw%'></span></div></td></tr>`n"}
    $html+="</tbody></table></div><h2>Compliance by Header-From domain</h2><table><thead><tr><th>Header-From</th><th class='num'>Messages</th><th class='num'>Compliant</th><th class='num'>Failed</th><th class='num'>Rate</th></tr></thead><tbody>`n"
    foreach($d in $byDomain){$rc=if($d.CompliancePct-ge95){'ok'}elseif($d.CompliancePct-lt80){'fail'}else{''}
        $html+="<tr><td>$($d.HeaderFrom)</td><td class='num'>$($d.Messages.ToString('N0'))</td><td class='num ok'>$($d.Compliant.ToString('N0'))</td><td class='num fail'>$($d.Failed.ToString('N0'))</td><td class='num $rc'>$($d.CompliancePct)%</td></tr>`n"}
    $html+="</tbody></table><h2>Reporting organisations</h2><table><thead><tr><th>Reporter</th><th class='num'>Reports</th><th class='num'>Messages</th></tr></thead><tbody>`n"
    foreach($r in $reporters){$html+="<tr><td>$($r.Reporter)</td><td class='num'>$($r.Reports)</td><td class='num'>$($r.Messages.ToString('N0'))</td></tr>`n"}
    $html+="</tbody></table><h2>Top non-compliant rows (max 100)</h2><table><thead><tr><th>Source IP</th><th>Header-From</th><th class='num'>Messages</th><th>Disposition</th><th>DKIM (aligned)</th><th>SPF (aligned)</th><th>Reporter</th></tr></thead><tbody>`n"
    foreach($f in $failures){$hn=if($IpCache.ContainsKey($f.SourceIP)){$IpCache[$f.SourceIP]}else{$null};$hd=if($hn){"<div class='ip-host'>$hn</div>"}else{''}
        $html+="<tr><td><code>$($f.SourceIP)</code>$hd</td><td>$($f.HeaderFrom)</td><td class='num'>$($f.MessageCount.ToString('N0'))</td><td>$($f.Disposition)</td><td class='fail'>$($f.DkimAligned)</td><td class='fail'>$($f.SpfAligned)</td><td class='small'>$($f.ReportOrg)</td></tr>`n"}
    $html+=@"
</tbody></table>
<h2>Domain details</h2><div class="domain-cards">$ddHtml</div>
<p class="small" style="margin-top:24px">DMARC compliance = aligned DKIM pass OR aligned SPF pass (per RFC 7489). Dashboard refreshes every 4 hours. SPF/DKIM alignment percentages are supplementary — a message can be DMARC compliant via DKIM even if SPF alignment fails.</p>
</body></html>
"@
    Set-Content -LiteralPath $Path -Value $html -Encoding UTF8
}
#endregion

#region --- Main ---
try{Get-AzStorageContainer -Name $archiveContainer -Context $ctx -EA Stop|Out-Null}catch{New-AzStorageContainer -Name $archiveContainer -Context $ctx -Permission Off|Out-Null;Write-Host "Created archive container."}

Write-Host "Scanning blobs..."
$rawBlobs=@(Get-AzStorageBlob -Container $rawContainer -Context $ctx -EA Stop)
$archiveBlobs=@(Get-AzStorageBlob -Container $archiveContainer -Context $ctx -EA SilentlyContinue)
$allBlobs=$rawBlobs+$archiveBlobs
Write-Host "Found $($rawBlobs.Count) in raw, $($archiveBlobs.Count) in archive."

$allRows=New-Object System.Collections.Generic.List[object];$processedBlobs=New-Object System.Collections.Generic.List[object];$processed=0;$skipped=0
foreach($blob in $allBlobs){
    if($blob.Name-notmatch'\.(xml|gz|zip)$'){$skipped++;continue}
    $isRaw=$blob.ICloudBlob.Container.Name-eq$rawContainer;$bc=if($isRaw){$rawContainer}else{$archiveContainer}
    $tmp=Join-Path $env:TEMP ([guid]::NewGuid().ToString('N')+[IO.Path]::GetExtension($blob.Name))
    try{
        Get-AzStorageBlobContent -Blob $blob.Name -Container $bc -Context $ctx -Destination $tmp -Force|Out-Null
        $fi=Get-Item -LiteralPath $tmp;$xmls=Expand-DmarcFile -File $fi;$blobYear=$null
        foreach($xml in $xmls){$rows=ConvertFrom-DmarcXml -Xml $xml;foreach($r in $rows){$allRows.Add($r)|Out-Null;if(-not $blobYear -and $r.BeginUtc){$blobYear=$r.BeginUtc.Year}}}
        if($isRaw){if(-not $blobYear){$blobYear=(Get-Date).ToUniversalTime().Year};$processedBlobs.Add(@{Name=$blob.Name;Year=$blobYear})|Out-Null}
        $processed++
    }catch{Write-Warning "Blob '$($blob.Name)' failed: $_"}
    finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue}}
}
Write-Host "Processed $processed blobs, skipped $skipped, parsed $($allRows.Count) rows."
if($allRows.Count-eq0){Write-Warning "No DMARC records.";return}

Write-Host "Resolving rDNS..."
$ipCache=@{};$allRows.SourceIP|Sort-Object -Unique|ForEach-Object{$ipCache[$_]=Get-RDnsName $_}
Write-Host "Resolved $(($ipCache.Values|Where-Object{$_}).Count) IPs."

$rowsArray=$allRows.ToArray()
$dayBuckets=Get-Last7DaysBuckets -Rows $rowsArray
$monthBuckets=Get-MonthBuckets -Rows $rowsArray
$domainSegments=$rowsArray|Group-Object HeaderFrom|ForEach-Object{[pscustomobject]@{HeaderFrom=$_.Name;Messages=($_.Group|Measure-Object MessageCount -Sum).Sum}}|Sort-Object Messages -Descending
$domainCompliance=$rowsArray|Group-Object HeaderFrom|ForEach-Object{$g=$_.Group;$t=($g|Measure-Object MessageCount -Sum).Sum;$p=($g|Where-Object Compliant|Measure-Object MessageCount -Sum).Sum;[pscustomobject]@{HeaderFrom=$_.Name;Messages=$t;Compliant=$p;Failed=$t-$p}}|Sort-Object Messages -Descending

Write-Host "Looking up DNS records..."
$domainDns=@{};$rowsArray.HeaderFrom|Sort-Object -Unique|ForEach-Object{$domainDns[$_]=Get-DomainDnsRecords -Domain $_}
Write-Host "DNS lookups complete."

Write-Host "Querying Azure costs..."
$monthlyCost=Get-AzureMonthlyCost -RG 'rg-dmarc'
Write-Host "Monthly cost: $monthlyCost"

$outHtml=Join-Path $env:TEMP 'index.html'
New-HtmlReport -Rows $rowsArray -Path $outHtml -IpCache $ipCache -DayBuckets $dayBuckets -MonthBuckets $monthBuckets -DomainSegments $domainSegments -DomainCompliance $domainCompliance -DomainDns $domainDns -MonthlyCost $monthlyCost
Set-AzStorageBlobContent -File $outHtml -Container $dashboardContainer -Blob 'index.html' -Context $ctx -Properties @{ContentType='text/html; charset=utf-8'} -Force|Out-Null
Remove-Item -LiteralPath $outHtml -Force -EA SilentlyContinue
Write-Host "Dashboard published."

if($processedBlobs.Count-gt0){
    Write-Host "Archiving $($processedBlobs.Count) blobs..."
    $archived=0
    foreach($pb in $processedBlobs){$dn="$($pb.Year)/$($pb.Name)"
        try{Start-AzStorageBlobCopy -SrcContainer $rawContainer -SrcBlob $pb.Name -DestContainer $archiveContainer -DestBlob $dn -Context $ctx -Force|Out-Null
            Get-AzStorageBlobCopyState -Container $archiveContainer -Blob $dn -Context $ctx -WaitForComplete|Out-Null
            Remove-AzStorageBlob -Container $rawContainer -Blob $pb.Name -Context $ctx -Force|Out-Null;$archived++
        }catch{Write-Warning "Archive failed '$($pb.Name)': $_"}}
    Write-Host "Archived $archived of $($processedBlobs.Count)."
}
#endregion
