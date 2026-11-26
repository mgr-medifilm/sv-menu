[CmdletBinding()]
param(
    [string]$MenuPageUrl = 'https://sv-gastronomie.ch/menu/Galexis%20AG,%20dailys,%20Niederbipp/Mittagsmen%C3%BC',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'public'),
    [string]$ToolsDirectory = $(if ($env:RUNNER_TEMP) { Join-Path $env:RUNNER_TEMP 'sv-menu-tools' } else { Join-Path ([IO.Path]::GetTempPath()) 'sv-menu-tools' }),
    [string]$BrowserPath,
    [string]$GeminiModel = $(if ($env:GEMINI_MODEL) { $env:GEMINI_MODEL } else { 'gemini-3.1-flash-lite' }),
    [switch]$SkipWeekCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-BrowserExecutable {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) {
            throw "Der angegebene Browser wurde nicht gefunden: $RequestedPath"
        }
        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $programFilesX86 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $programFilesX86 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    foreach ($name in @('msedge.exe', 'chrome.exe')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command -and $command.Source -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $command.Source).Path
        }
    }

    throw 'Microsoft Edge oder Google Chrome wurde nicht gefunden. Installiere einen der Browser oder gib -BrowserPath an.'
}

function ConvertTo-WindowsCommandLineArgument {
    param([string]$Value)

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        [void]$builder.Append(('\' * $backslashes))
        [void]$builder.Append($character)
        $backslashes = 0
    }
    [void]$builder.Append(('\' * ($backslashes * 2)))
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-RenderedPageHtml {
    param(
        [string]$Browser,
        [string]$Url,
        [string]$WorkDirectory
    )

    $profile = Join-Path $WorkDirectory 'browser-profile'
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Browser
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $arguments = @(
        '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
        '--disable-extensions', '--disable-background-networking', '--hide-scrollbars',
        '--virtual-time-budget=15000', "--user-data-dir=$profile", '--dump-dom', $Url
    )
    $commandLineParts = foreach ($argument in $arguments) { ConvertTo-WindowsCommandLineArgument -Value $argument }
    $startInfo.Arguments = $commandLineParts -join ' '

    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
    } catch {
        throw "Der Browser konnte unter '$Browser' nicht gestartet werden. Prüfe den Pfad oder gib ihn mit -BrowserPath an. Ursache: $($_.Exception.Message)"
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(90000)) {
        try { $process.Kill() } catch { }
        throw 'Der Browser hat die Menüseite nicht innerhalb von 90 Sekunden geladen.'
    }
    $process.WaitForExit()
    $html = $stdoutTask.GetAwaiter().GetResult()
    $browserError = $stderrTask.GetAwaiter().GetResult()

    if ([string]::IsNullOrWhiteSpace($html) -or $html -notmatch '(?i)<html') {
        throw "Der Browser hat kein gerendertes HTML geliefert. $browserError"
    }
    return $html
}

function Find-WeeklyPdfUrl {
    param([string]$Html, [string]$PageUrl)

    $candidates = [System.Collections.Generic.List[object]]::new()
    $searchHtml = [System.Net.WebUtility]::HtmlDecode($Html)
    $searchHtml = $searchHtml -replace '\\/', '/' -replace '\\u0026', '&' -replace '\\u003d', '='
    $anchorPattern = '(?is)<a\b(?<attrs>[^>]*)>(?<inner>.*?)</a>'
    $uriAttributePattern = '(?is)\b(?:href|data-href|data-url|data-download-url)\s*=\s*(?:"(?<v>[^"]*)"|''(?<v>[^'']*)''|(?<v>[^\s>]+))'

    foreach ($match in [regex]::Matches($searchHtml, $anchorPattern)) {
        $attrs = $match.Groups['attrs'].Value
        $inner = $match.Groups['inner'].Value
        $label = [System.Net.WebUtility]::HtmlDecode(($inner -replace '(?is)<[^>]+>', ' '))
        $label = ($label -replace '[\s\u00a0]+', ' ').Trim()
        $labelAttribute = [regex]::Match($attrs, '(?is)\b(?:aria-label|title|alt)\s*=\s*(?:"(?<v>[^"]*)"|''(?<v>[^'']*)''|(?<v>[^\s>]+))')
        $isPlanLabel = ($label -match '(?i)^Wochenmen[uü]plan$') -or
            ($labelAttribute.Success -and [System.Net.WebUtility]::HtmlDecode($labelAttribute.Groups['v'].Value).Trim() -match '(?i)^Wochenmen[uü]plan$')

        $uriValues = [System.Collections.Generic.List[string]]::new()
        foreach ($attrMatch in [regex]::Matches($attrs, $uriAttributePattern)) {
            $value = [System.Net.WebUtility]::HtmlDecode($attrMatch.Groups['v'].Value).Trim()
            if ($value -and $value -notin @('#','javascript:void(0)','javascript:void(0);')) { $uriValues.Add($value) }
        }
        if ($uriValues.Count -eq 0 -and $isPlanLabel) {
            foreach ($urlMatch in [regex]::Matches($match.Value, '(?i)(?:https?:)?//[^"''<>\s]+|/release-menu-pdfs/[^"''<>\s]+')) {
                $uriValues.Add($urlMatch.Value)
            }
        }

        foreach ($value in $uriValues) {
            $value = $value.TrimEnd([char[]]@(')',']','}',',',';'))
            try { $absoluteUri = [Uri]::new([Uri]$PageUrl, $value) } catch { continue }
            if ($absoluteUri.Scheme -notin @('http','https')) { continue }
            $score = if ($isPlanLabel) { 100 } else { 0 }
            if ($absoluteUri.AbsolutePath -match '(?i)release-menu-pdfs') { $score += 10 }
            if ($absoluteUri.AbsolutePath -match '(?i)\.pdf$') { $score += 5 }
            if ($score -gt 0) { $candidates.Add([pscustomobject]@{ Uri = $absoluteUri; Score = $score; Text = $label }) }
        }
    }

    # Fallback for a Qnips URL embedded in page data rather than an anchor.
    $rawUrlPattern = '(?i)(?<url>(?:https?:)?//[^"''<>\s]*release-menu-pdfs/[^"''<>\s]*?\.pdf(?:\?[^"''<>\s]*)?|/release-menu-pdfs/[^"''<>\s]*?\.pdf(?:\?[^"''<>\s]*)?)'
    foreach ($rawMatch in [regex]::Matches($searchHtml, $rawUrlPattern)) {
        $rawUrl = $rawMatch.Groups['url'].Value.TrimEnd([char[]]@(')',']','}',',',';'))
        if ($rawUrl.StartsWith('//')) { $rawUrl = 'https:' + $rawUrl }
        try { $absoluteUri = [Uri]::new([Uri]$PageUrl, $rawUrl) } catch { continue }
        if ($absoluteUri.Scheme -in @('http','https')) {
            $candidates.Add([pscustomobject]@{ Uri = $absoluteUri; Score = 20; Text = 'embedded qnips url' })
        }
    }

    if ($candidates.Count -eq 0) {
        $anchorCount = [regex]::Matches($searchHtml, '(?is)<a\b').Count
        $labelCount = [regex]::Matches($searchHtml, '(?i)Wochenmen[uü]plan').Count
        $qnipsCount = [regex]::Matches($searchHtml, '(?i)release-menu-pdfs|files\.qnips\.com').Count
        throw "Kein Link zum Eintrag Wochenmenüplan gefunden. Diagnose: $anchorCount Links, $labelCount Treffer zum Eintragstext und $qnipsCount Qnips Hinweise im Seiteninhalt."
    }
    return ($candidates | Sort-Object Score -Descending | Select-Object -First 1).Uri
}

function Get-PdfInfoValue {
    param([string[]]$Lines, [string]$Name)
    $line = $Lines | Where-Object { $_ -match "^$([regex]::Escape($Name)):\s*" } | Select-Object -First 1
    if ($line -and $line -match '^.*?:\s*(?<value>.+?)\s*$') { return $Matches['value'] }
    return $null
}

function Get-IsoWeekInfo {
    param([datetime]$Date)

    $mondayOffset = ([int]$Date.DayOfWeek + 6) % 7
    $monday = $Date.Date.AddDays(-$mondayOffset)
    $isoYear = $monday.AddDays(3).Year
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $januaryFourth = [datetime]::ParseExact("$isoYear-01-04", 'yyyy-MM-dd', $culture)
    $firstMondayOffset = ([int]$januaryFourth.DayOfWeek + 6) % 7
    $firstMonday = $januaryFourth.Date.AddDays(-$firstMondayOffset)
    $week = 1 + [int][Math]::Floor(($monday - $firstMonday).TotalDays / 7)

    return [pscustomobject]@{ Week = $week; Year = $isoYear }
}

function Get-PopplerTools {
    param(
        [string]$DestinationDirectory,
        [string]$WorkDirectory,
        [string]$Version,
        [string]$ExpectedSha256
    )

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'Das portable Poppler Paket ist für 64 Bit Windows vorgesehen.'
    }

    if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    }

    $cacheDirectory = Join-Path $DestinationDirectory "poppler-$Version"
    $cachedPdfInfo = Get-ChildItem -LiteralPath $cacheDirectory -Filter 'pdfinfo.exe' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cachedPdfInfo) {
        $binDirectory = $cachedPdfInfo.Directory.FullName
        $cachedPdfToPpm = Join-Path $binDirectory 'pdftoppm.exe'
        $cachedPdfToText = Join-Path $binDirectory 'pdftotext.exe'
        if ((Test-Path -LiteralPath $cachedPdfToPpm -PathType Leaf) -and (Test-Path -LiteralPath $cachedPdfToText -PathType Leaf)) {
            return [pscustomobject]@{ PdfInfo = $cachedPdfInfo.FullName; PdfToPpm = $cachedPdfToPpm; PdfToText = $cachedPdfToText }
        }
    }

    $archiveName = "Release-$Version.zip"
    $downloadUri = "https://github.com/oschwartz10612/poppler-windows/releases/download/v$Version/$archiveName"
    $archivePath = Join-Path $WorkDirectory $archiveName
    Write-Host "Lade portables Poppler $Version herunter ..."
    Invoke-WebRequest -Uri $downloadUri -OutFile $archivePath -MaximumRedirection 5

    $actualSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $ExpectedSha256) {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        throw "Die Prüfsumme des Poppler Downloads stimmt nicht. Erwartet $ExpectedSha256, erhalten $actualSha256."
    }

    if (Test-Path -LiteralPath $cacheDirectory) {
        Remove-Item -LiteralPath $cacheDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
    Expand-Archive -LiteralPath $archivePath -DestinationPath $cacheDirectory -Force

    $pdfInfo = Get-ChildItem -LiteralPath $cacheDirectory -Filter 'pdfinfo.exe' -File -Recurse | Select-Object -First 1
    if (-not $pdfInfo) { throw 'Im heruntergeladenen Poppler Paket fehlt pdfinfo.exe.' }
    $pdfToPpm = Join-Path $pdfInfo.Directory.FullName 'pdftoppm.exe'
    if (-not (Test-Path -LiteralPath $pdfToPpm -PathType Leaf)) { throw 'Im heruntergeladenen Poppler Paket fehlt pdftoppm.exe.' }
    $pdfToText = Join-Path $pdfInfo.Directory.FullName 'pdftotext.exe'
    if (-not (Test-Path -LiteralPath $pdfToText -PathType Leaf)) { throw 'Im heruntergeladenen Poppler Paket fehlt pdftotext.exe.' }

    return [pscustomobject]@{ PdfInfo = $pdfInfo.FullName; PdfToPpm = $pdfToPpm; PdfToText = $pdfToText }
}

function Convert-MenuHtmlToPdf {
    param([string]$Browser, [string]$HtmlPath, [string]$PdfPath, [string]$WorkDirectory)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Browser
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $htmlUri = ([Uri]::new((Resolve-Path -LiteralPath $HtmlPath).Path)).AbsoluteUri
    $arguments = @(
        '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
        '--disable-extensions', '--disable-background-networking', '--no-pdf-header-footer',
        "--user-data-dir=$(Join-Path $WorkDirectory 'render-profile')", "--print-to-pdf=$PdfPath",
        '--virtual-time-budget=10000', $htmlUri
    )
    $commandLineParts = foreach ($argument in $arguments) { ConvertTo-WindowsCommandLineArgument -Value $argument }
    $startInfo.Arguments = $commandLineParts -join ' '
    try { $process = [System.Diagnostics.Process]::Start($startInfo) }
    catch { throw "Der Browser konnte die gestaltete Menüseite nicht rendern. $($_.Exception.Message)" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(90000)) {
        try { $process.Kill() } catch { }
        throw 'Das Erstellen der gestalteten Menüseite dauerte länger als 90 Sekunden.'
    }
    $process.WaitForExit()
    [void]$stdoutTask.GetAwaiter().GetResult()
    $browserError = $stderrTask.GetAwaiter().GetResult()
    if (-not (Test-Path -LiteralPath $PdfPath -PathType Leaf)) {
        throw "Der Browser hat die gestaltete Menüseite nicht als PDF ausgegeben. $browserError"
    }
}

$popplerVersion = '26.09.0-0'
$popplerSha256 = '7a6f256a0ddf7536182246a5733331bf4677cbcc34f4663774947ad34556c8d0'

function Normalize-SourceText {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return (($Value -replace '\s+', ' ').Trim()).ToLowerInvariant()
}

function Get-GeminiMenuData {
    param([string]$SourceText, [string]$Model)
    $apiKey = $env:GEMINI_API_KEY
    if ([string]::IsNullOrWhiteSpace($apiKey)) { throw 'Das GitHub Secret GEMINI_API_KEY fehlt.' }

    $instructions = @'
Du ordnest den Inhalt eines Wochenmenü PDF in feste Felder ein.
Nutze nur den unten gelieferten PDF Text. Erfinde, ergänze, übersetze oder interpretiere nichts.
Übernimm Gerichtsnamen und Beschreibungen exakt aus dem Text. Entferne Preise und Zusatzinformationen.
Gib Montag bis Freitag mit genau diesen drei Kategorien aus: CHEF'S CHOICE, HOME, WORLD!
Ein Menü besteht aus Kategorie, Gericht und optionaler Beschreibung oder Beilagen.
Übernimm den im PDF angegebenen Zeitraum exakt.
Fehlt ein Tag, eine Kategorie oder eine eindeutige Zuordnung, setze valid auf false und nenne den Grund in errors. Fülle nichts auf.
Antworte ausschliesslich als JSON mit diesem Aufbau:
{
  "valid": true,
  "period_original": "Zeitraum exakt aus dem PDF",
  "days": [
    {"day":"Montag","menus":[{"category":"CHEF'S CHOICE","dish":"...","description":"..."},{"category":"HOME","dish":"...","description":"..."},{"category":"WORLD!","dish":"...","description":"..."}]},
    {"day":"Dienstag","menus":[...]},
    {"day":"Mittwoch","menus":[...]},
    {"day":"Donnerstag","menus":[...]},
    {"day":"Freitag","menus":[...]}
  ],
  "errors": []
}
Wenn keine Beschreibung im Original steht, verwende einen leeren Text.
'@
    $body = @{
        system_instruction = @{ parts = @(@{ text = $instructions }) }
        contents = @(@{ role = 'user'; parts = @(@{ text = "PDF Text:`n$SourceText" }) })
        generationConfig = @{ temperature = 0; responseMimeType = 'application/json' }
    } | ConvertTo-Json -Depth 20
    $uri = "https://generativelanguage.googleapis.com/v1beta/models/$Model`:generateContent?key=$apiKey"
    try {
        $response = Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/json' -Body $body -TimeoutSec 120
    } catch {
        throw 'Die Gemini API Anfrage ist fehlgeschlagen. Prüfe das Secret, das Modell und die API Kontingente.'
    }
    $jsonText = (($response.candidates[0].content.parts | ForEach-Object { $_.text }) -join '').Trim()
    if (-not $jsonText) { throw 'Gemini hat keine JSON Antwort zurückgegeben.' }
    try { return ($jsonText | ConvertFrom-Json) } catch { throw 'Die Gemini Antwort war kein gültiges JSON.' }
}

function Assert-MenuData {
    param($Data, [string]$SourceText)
    if ($Data.valid -ne $true) { throw "KI konnte den Plan nicht eindeutig lesen: $(@($Data.errors) -join '; ')" }
    if ([string]::IsNullOrWhiteSpace([string]$Data.period_original)) { throw 'Der Zeitraum fehlt in der KI Antwort.' }
    $dayNames = @('Montag','Dienstag','Mittwoch','Donnerstag','Freitag')
    $categories = @("CHEF'S CHOICE",'HOME','WORLD!')
    if (@($Data.days).Count -ne 5) { throw 'Die KI Antwort enthält nicht genau fünf Wochentage.' }
    $normalizedSource = Normalize-SourceText $SourceText
    for ($i=0; $i -lt 5; $i++) {
        $day = $Data.days[$i]
        if ($day.day -ne $dayNames[$i]) { throw "Tagesfolge oder Tag ist ungültig bei $($dayNames[$i])." }
        if (@($day.menus).Count -ne 3) { throw "Für $($day.day) wurden nicht genau drei Menüs geliefert." }
        for ($j=0; $j -lt 3; $j++) {
            $menu = $day.menus[$j]
            if ($menu.category -ne $categories[$j]) { throw "Kategorie für $($day.day) ist ungültig oder in falscher Reihenfolge." }
            if ([string]::IsNullOrWhiteSpace([string]$menu.dish)) { throw "Gerichtsname fehlt für $($day.day), $($menu.category)." }
            foreach ($field in @('dish','description')) {
                $value = [string]$menu.$field
                if ($value -and -not $normalizedSource.Contains((Normalize-SourceText $value))) {
                    throw "Der Text '$value' für $($day.day) ist nicht wörtlich im PDF Text auffindbar. Veröffentlichung abgebrochen."
                }
                if ($value -match '(?i)CHF|\bFr\.?\s*\d|\d+[.,]\d{2}') { throw 'Die KI Antwort enthält möglicherweise einen Preis. Veröffentlichung abgebrochen.' }
            }
        }
    }
    if (-not $normalizedSource.Contains((Normalize-SourceText ([string]$Data.period_original)))) {
        throw 'Der Zeitraum ist im PDF Text nicht exakt auffindbar.'
    }
}

function HtmlEncode([string]$Text) { return [System.Net.WebUtility]::HtmlEncode($Text) }

function New-MenuHtml {
    param($Data, [int]$Week, [int]$Year, [datetime]$WeekStart)
    $dayMarkup = [System.Text.StringBuilder]::new()
    for ($i=0; $i -lt 5; $i++) {
        $day = $Data.days[$i]
        $date = $WeekStart.AddDays($i).ToString('dd.MM.')
        [void]$dayMarkup.AppendLine("<section class='day'><header><h2>$(HtmlEncode $day.day)</h2><span>$date</span></header>")
        foreach ($menu in $day.menus) {
            [void]$dayMarkup.AppendLine("<article class='menu'><div class='category'>$(HtmlEncode $menu.category)</div><h3>$(HtmlEncode $menu.dish)</h3>")
            if ($menu.description) { [void]$dayMarkup.AppendLine("<p>$(HtmlEncode $menu.description)</p>") }
            [void]$dayMarkup.AppendLine('</article>')
        }
        [void]$dayMarkup.AppendLine('</section>')
    }
    $period = HtmlEncode ([string]$Data.period_original)
    return @"
<!doctype html><html lang="de"><head><meta charset="utf-8"><title>Wochenmenü KW $Week $Year</title>
<style>
@page{size:16in 9in;margin:0}*{box-sizing:border-box}html,body{width:16in;height:9in;margin:0}body{padding:28px 34px 24px;background:#f2f5f8;color:#182b40;font-family:Segoe UI,Arial,sans-serif;display:flex;flex-direction:column;overflow:hidden;-webkit-print-color-adjust:exact;print-color-adjust:exact}.top{height:112px;flex:none;display:flex;align-items:center;justify-content:space-between;border-bottom:3px solid #209f9b;margin-bottom:18px}.top h1{font-size:38px;margin:0 0 6px;letter-spacing:1px}.period{font-size:19px;color:#526579}.brand{text-align:right;color:#17736f;font-weight:700;letter-spacing:2px;font-size:20px}.days{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:12px;flex:1;min-height:0}.day{background:white;border:1px solid #d7e0e8;border-top:5px solid #209f9b;border-radius:12px;padding:13px 13px 10px;min-width:0;overflow:hidden}.day header{display:flex;justify-content:space-between;align-items:baseline;border-bottom:1px solid #e1e8ef;padding-bottom:8px;margin-bottom:6px}.day h2{font-size:22px;margin:0}.day header span{font-size:15px;color:#65758a}.menu{padding:8px 0 7px;border-bottom:1px solid #edf1f4}.menu:last-child{border-bottom:0}.category{font-size:13px;font-weight:800;color:#167875;letter-spacing:.6px;margin-bottom:3px}.menu h3{font-size:17px;line-height:1.2;margin:0 0 4px;color:#20374e}.menu p{font-size:15px;line-height:1.25;margin:0;color:#536477}.footer{height:18px;flex:none;text-align:right;font-size:11px;color:#718094;padding-top:4px}
</style></head><body><div class="top"><div><h1>WOCHENMENÜ</h1><div class="period">KW $Week / $Year&nbsp;&nbsp;·&nbsp;&nbsp;$period</div></div><div class="brand">GALEXIS<br><span style="font-size:13px;font-weight:500;letter-spacing:.5px">Niederbipp</span></div></div><main class="days">$($dayMarkup.ToString())</main><div class="footer">Wochenübersicht · ohne Preise</div></body></html>
"@
}

$browser = Get-BrowserExecutable -RequestedPath $BrowserPath
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$workDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('SvWeeklyMenu_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    $pdfTools = Get-PopplerTools -DestinationDirectory $ToolsDirectory -WorkDirectory $workDirectory -Version $popplerVersion -ExpectedSha256 $popplerSha256
    Write-Host 'Lade Menüseite und suche den aktuellen PDF Download ...'
    $pageHtml = Get-RenderedPageHtml -Browser $browser -Url $MenuPageUrl -WorkDirectory $workDirectory
    try {
        $pdfUri = Find-WeeklyPdfUrl -Html $pageHtml -PageUrl $MenuPageUrl
    } catch {
        Write-Host 'Kein PDF Link im gerenderten DOM. Prüfe ergänzend den HTML Seiteninhalt ...'
        try {
            $staticResponse = Invoke-WebRequest -Uri $MenuPageUrl -MaximumRedirection 5 -TimeoutSec 60
            $combinedHtml = $pageHtml + "`n" + [string]$staticResponse.Content
            $pdfUri = Find-WeeklyPdfUrl -Html $combinedHtml -PageUrl $MenuPageUrl
        } catch {
            throw 'Die Menüseite lieferte weder im gerenderten DOM noch im HTML Quelltext einen Wochenmenü PDF Link. Der Download wurde nicht verändert und es wurde keine Ausgabe veröffentlicht.'
        }
    }
    $decodedName = [Uri]::UnescapeDataString([System.IO.Path]::GetFileName($pdfUri.AbsolutePath))
    if ($decodedName -notmatch '(?i)_(?<week>\d{1,2})_(?<date>\d{8})_') { throw "Unerwartetes Wochenmenü PDF Dateimuster: $decodedName" }
    $fileWeek = [int]$Matches.week
    $menuDate = [datetime]::ParseExact($Matches.date,'yyyyMMdd',[Globalization.CultureInfo]::InvariantCulture)
    $iso = Get-IsoWeekInfo -Date $menuDate
    if ($fileWeek -ne $iso.Week) { throw 'Kalenderwoche im Dateinamen und Datumsanteil stimmen nicht überein.' }
    if (-not $SkipWeekCheck) {
        $current = Get-IsoWeekInfo -Date (Get-Date).Date
        if ($iso.Week -ne $current.Week -or $iso.Year -ne $current.Year) { throw "SV lieferte KW $($iso.Week)/$($iso.Year), erwartet KW $($current.Week)/$($current.Year)." }
    }
    $sourcePdf = Join-Path $workDirectory $decodedName
    Write-Host "Lade PDF KW $($iso.Week)/$($iso.Year) herunter ..."
    Invoke-WebRequest -Uri $pdfUri.AbsoluteUri -OutFile $sourcePdf -MaximumRedirection 5
    $signature = [System.IO.File]::ReadAllBytes($sourcePdf)
    if ($signature.Length -lt 5 -or [Text.Encoding]::ASCII.GetString($signature,0,5) -ne '%PDF-') { throw 'Der Download ist keine gültige PDF.' }
    $pdfInfo = & $pdfTools.PdfInfo $sourcePdf 2>&1
    if ($LASTEXITCODE -ne 0 -or [int](Get-PdfInfoValue -Lines $pdfInfo -Name 'Pages') -ne 1) { throw 'Das Original PDF enthält nicht genau eine Seite.' }
    $textPath = Join-Path $workDirectory 'source.txt'
    & $pdfTools.PdfToText -layout -enc UTF-8 $sourcePdf $textPath
    if ($LASTEXITCODE -ne 0) { throw 'Der Text konnte nicht aus dem PDF extrahiert werden.' }
    $sourceText = [IO.File]::ReadAllText($textPath,[Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($sourceText)) { throw 'Das PDF enthält keinen auslesbaren Text.' }

    Write-Host 'Ordne Menüs mit Gemini zu und prüfe die Antwort ...'
    $data = Get-GeminiMenuData -SourceText $sourceText -Model $GeminiModel
    Assert-MenuData -Data $data -SourceText $sourceText

    $htmlPath = Join-Path $workDirectory 'menu.html'
    [IO.File]::WriteAllText($htmlPath,(New-MenuHtml -Data $data -Week $iso.Week -Year $iso.Year -WeekStart $menuDate),[Text.UTF8Encoding]::new($false))
    $styledPdf = Join-Path $workDirectory 'final.pdf'
    Convert-MenuHtmlToPdf -Browser $browser -HtmlPath $htmlPath -PdfPath $styledPdf -WorkDirectory $workDirectory
    $finalInfo = & $pdfTools.PdfInfo $styledPdf 2>&1
    if ($LASTEXITCODE -ne 0 -or [int](Get-PdfInfoValue -Lines $finalInfo -Name 'Pages') -ne 1) { throw 'Das gestaltete Menü passt nicht auf genau eine PDF Seite.' }
    $jpgBase = Join-Path $workDirectory 'wochenmenu'
    & $pdfTools.PdfToPpm -f 1 -l 1 -singlefile -jpeg -r 120 $styledPdf $jpgBase
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$jpgBase.jpg")) { throw 'Das JPG konnte nicht erstellt werden.' }

    $pdfName = "Wochenmenu_KW_$($iso.Week)_$($iso.Year)_Infoscreen.pdf"
    $stage = Join-Path $workDirectory 'publish'
    New-Item -ItemType Directory -Path $stage | Out-Null
    Copy-Item $styledPdf (Join-Path $stage $pdfName)
    Copy-Item "$jpgBase.jpg" (Join-Path $stage 'wochenmenu.jpg')
    $index = @"
<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Wochenmenü Galexis Niederbipp</title><style>body{margin:0;background:#eaf0f4;color:#183047;font-family:Segoe UI,Arial,sans-serif;text-align:center}.bar{padding:16px}.bar a{display:inline-block;margin:4px;padding:11px 18px;background:#167875;color:white;text-decoration:none;border-radius:7px;font-weight:700}img{display:block;width:min(100%,1920px);height:auto;margin:auto}</style></head><body><div class="bar"><a href="wochenmenu.jpg">JPG für Infoscreen</a><a href="$pdfName">PDF herunterladen</a></div><img src="wochenmenu.jpg" alt="Wochenmenü KW $($iso.Week) $($iso.Year)"></body></html>
"@
    [IO.File]::WriteAllText((Join-Path $stage 'index.html'),$index,[Text.UTF8Encoding]::new($false))
    if (Test-Path $OutputDirectory) { Get-ChildItem -LiteralPath $OutputDirectory -Force | Remove-Item -Recurse -Force }
    Copy-Item (Join-Path $stage '*') $OutputDirectory -Recurse -Force
    Write-Host "Erstellt: $OutputDirectory"
    Write-Host "PDF: $pdfName"
    Write-Host "Woche: KW $($iso.Week)/$($iso.Year)"
} finally {
    Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
