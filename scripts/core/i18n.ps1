# i18n.ps1 - locale layer for agent/user-facing console text.
#
# Display templates live in DATA files: config\i18n.<lang>.psd1 (default
# zh-CN). This loader is written once and never edited for wording.
#   Get-AkText  - one-line template lookup ({0}{1}... format args)
#   Get-AkLines - multi-line mail body lookup (array of lines, '' = blank)
#   Get-AkStatusName - .status sidecar code -> display name
#
# Fallback contract: the $En argument at each call site is the legacy English
# template, returned verbatim when the table is missing, corrupt or lacks the
# key. AK_LANG=en (or any unknown lang) therefore reproduces today's English
# output byte-for-byte. Machine surfaces (.status values, .progress STATUS and
# DISPATCHED lines, journal actions, exit codes, sys-mail subjects) stay ASCII
# by design - they are the mapping keys, never localized.

if (-not $env:AK_LANG) { $env:AK_LANG = 'zh-CN' }
$script:AkLang  = ''
$script:AkTable = $null

function Get-AkTable {
    # Load (and cache per process) config\i18n.<lang>.psd1 for the active language.
    $lang = if ($env:AK_LANG) { $env:AK_LANG } else { 'zh-CN' }
    if ($script:AkLang -ne $lang) {
        $script:AkLang = $lang
        $script:AkTable = $null
        try {
            $p = Join-Path $script:Root ('config\i18n.' + $lang + '.psd1')
            if (Test-Path -LiteralPath $p) { $script:AkTable = Import-PowerShellDataFile -LiteralPath $p }
        } catch { $script:AkTable = $null }   # corrupt table -> English fallback
    }
    return $script:AkTable
}

function Get-AkText {
    # Localized one-line template. Extra positional args feed {0}{1}...
    param([string]$Key, [string]$En)
    $fmt = @($args)
    $tpl = $En
    try {
        $t = Get-AkTable
        if ($t -and $t.ContainsKey($Key)) { $tpl = [string]$t[$Key] }
    } catch { $tpl = $En }
    if ($fmt.Count -and $tpl -match '\{') {
        try { return ($tpl -f $fmt) } catch { return $tpl }
    }
    return $tpl
}

function Get-AkLines {
    # Localized multi-line body: array of lines ('' = blank separator line).
    param([string]$Key)
    $def = @($args)
    $v = $null
    try {
        $t = Get-AkTable
        if ($t -and $t.ContainsKey($Key)) { $v = $t[$Key] }
    } catch { $v = $null }
    if ($null -eq $v) { return $def }
    return @($v | ForEach-Object { [string]$_ })
}

function Get-AkStatusName {
    # .status sidecar code (DELIVERED / RETURNED / ...) -> display name.
    # Unknown codes pass through unchanged, in every language.
    param([string]$Code)
    if (-not $Code) { return $Code }
    return (Get-AkText -Key ('status.' + $Code) -En $Code)
}
