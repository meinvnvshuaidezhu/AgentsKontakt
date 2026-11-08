param(
  [string]$Agent,      # either side of the conversation
  [string]$With,       # counterpart, used together with -Agent (their pairwise history)
  [string]$From,       # topic initiator
  [string]$To,         # first recipient
  [string]$Model,      # substring match against initiator/recipient model
  [string]$Date,       # yyyy-MM-dd (topic initiation date)
  [string]$Month,      # yyyy-MM
  [string]$Year,       # yyyy
  [string]$Topic,      # exact topic id t-...
  [string]$Keyword,    # substring in title or summary body
  [switch]$Message,    # also search message bodies under matched topic dirs
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    elseif ($PSScriptRoot) { $Root = Split-Path $PSScriptRoot -Parent }
    else { $Root = (Get-Location).Path }
}
. (Join-Path $PSScriptRoot 'core\common.ps1')

# Query closed topics. Reads front-matter of every archive\<agent>\<yyyy>\<MM>\<dd>\<topic>\summary.md
# and prints matching topics with the full summary path (messages live beside it).
# Index files for manual browsing: archive\index.md, archive\<agent>\_index.md.

if (-not (Test-Path -LiteralPath $script:DirArchive)) { Write-Host (Get-AkText 'aq.no-archive' 'no archive yet'); exit 0 }

$haveFilter = @($Agent, $With, $From, $To, $Model, $Date, $Month, $Year, $Topic, $Keyword | Where-Object { $_ })
if (-not $haveFilter) {
    Write-Host (Get-AkText 'aq.usage1' 'Usage: archive-query.ps1 [-Agent name] [-With name] [-From name] [-To name] [-Model id]')
    Write-Host (Get-AkText 'aq.usage2' '                       [-Date yyyy-MM-dd] [-Month yyyy-MM] [-Year yyyy] [-Topic t-...] [-Keyword text] [-Message]')
    Write-Host (Get-AkText 'aq.usage3' 'Indexes: archive\index.md (global), archive\<agent>\_index.md (per agent)')
    $names = @((Get-RegisteredAgents | ForEach-Object { $_.name }) | Sort-Object) -join ', '
    Write-Host (Get-AkText 'aq.agents' 'Registered agents: {0}' $names)
    exit 0
}

$hits = @()
foreach ($f in (Get-ChildItem -LiteralPath $script:DirArchive -Recurse -Filter 'summary.md' -File -ErrorAction SilentlyContinue)) {
    $fm = Read-FrontMatter -Path $f.FullName
    $tp = [string]$fm['topic']; if (-not $tp) { $tp = (Split-Path (Split-Path $f.FullName -Parent) -Leaf) }
    $ti = [string]$fm['title']; $fr = [string]$fm['from']; $to = [string]$fm['to']
    $frm = Format-ModelValue -Value ([string]$fm['from_model']); $tom = Format-ModelValue -Value ([string]$fm['to_model'])
    $dt = [string]$fm['date']; $cl = [string]$fm['closed']
    $ok = $true
    if ($ok -and $Topic -and $tp -ne $Topic) { $ok = $false }
    if ($ok -and $From -and $fr -ne $From) { $ok = $false }
    if ($ok -and $To -and $to -ne $To) { $ok = $false }
    if ($ok -and $Agent) {
        $involves = (($fr -eq $Agent) -or ($to -eq $Agent))
        if ($With) { if (-not ($involves -and (($fr -eq $With) -or ($to -eq $With)))) { $ok = $false } }
        elseif (-not $involves) { $ok = $false }
    }
    if ($ok -and $Model) {
        $m = ([string]$frm + ' ' + [string]$tom)
        if ($m.ToLower().IndexOf($Model.ToLower()) -lt 0) { $ok = $false }
    }
    if ($ok -and $Date -and $dt -ne $Date) { $ok = $false }
    if ($ok -and $Month -and (-not $dt.StartsWith($Month))) { $ok = $false }
    if ($ok -and $Year -and (-not $dt.StartsWith($Year))) { $ok = $false }
    if ($ok -and $Keyword) {
        $hay = [string]$ti
        if ($Message) {
            $dir = Split-Path $f.FullName -Parent
            foreach ($mf in (Get-ChildItem -LiteralPath $dir -File -Filter '*.md' -ErrorAction SilentlyContinue)) {
                if ($mf.Name -ne 'summary.md') { $hay += ' ' + [System.IO.File]::ReadAllText($mf.FullName) }
            }
        } else {
            $hay += ' ' + [System.IO.File]::ReadAllText($f.FullName)
        }
        if ($hay.ToLower().IndexOf($Keyword.ToLower()) -lt 0) { $ok = $false }
    }
    if ($ok) {
        $hits += New-Object PSObject -Property @{ date = $dt; topic = $tp; title = $ti
            from = $fr; from_model = $frm; to = $to; to_model = $tom; closed = $cl; path = $f.FullName }
    }
}

$hits = @($hits | Sort-Object -Property @{Expression='closed';Descending=$true})
Write-Host (Get-AkText 'aq.matched' '# {0} topic(s) matched' $hits.Count)
foreach ($h in $hits) {
    Write-Host ('- ' + $h.date + ' | ' + $h.topic + ' | ' + $h.from + '(' + $h.from_model + ') -> ' + $h.to + '(' + $h.to_model + ') | ' + $h.title)
    Write-Host ('  ' + $h.path)
}
exit 0
