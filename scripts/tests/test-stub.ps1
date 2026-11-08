param(
  [Parameter(Mandatory=$true)][string]$Prompt,
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    else {
        # the script may sit in a subdir - walk up to the data root (a dir holding registry\)
        $d = $PSScriptRoot
        while ($d -and -not (Test-Path -LiteralPath (Join-Path $d 'registry'))) { $d = Split-Path $d -Parent }
        if ($d) { $Root = $d } elseif ($PSScriptRoot) { $Root = Split-Path $PSScriptRoot -Parent }
        else { $Root = (Get-Location).Path }
    }
}
. (Join-Path $PSScriptRoot '..\core\common.ps1')

# Test stub: simulates a PUSH-mode agent. Parses the dispatch prompt, "does
# the work", writes a protocol-compliant reply to its own outbox and sends it.

if ($Prompt -notmatch 'NEW-MAIL:\s*([^\s\x27"]+)') { Write-Error 'stub: cannot parse NEW-MAIL path'; exit 1 }
$msg = $Matches[1]
if (-not (Test-Path -LiteralPath $msg)) { Write-Error ('stub: message not found: ' + $msg); exit 1 }

$fm = Read-FrontMatter -Path $msg
& (Join-Path $PSScriptRoot '..\progress.ps1') -File $msg -Note 'stub: got the mail, starting to work' -Root $Root

# NO-REPLY guard: a message body containing NO-REPLY is handled (archived by
# the sender side / close.ps1) without a reply. Prevents echo ping-pong when
# the other party is also an auto-replier (e.g. a real PUSH agent).
if ((Read-TextFile -Path $msg) -match 'NO-REPLY') {
    Write-Host ('stub: NO-REPLY marker; handled ' + $fm['id'] + ' without reply')
    # Acceptance round-trip tail: a NO-REPLY reply to a request testbot itself
    # initiated (ACCEPTANCE-TEST) means the channel verification finished -
    # close the topic as the initiator so no test mail lingers in processing.
    if ([string]$fm['type'] -eq 'reply' -and $fm['in_reply_to']) {
        $orig = Get-ChildItem -LiteralPath $script:DirMailboxes, $script:DirArchive -Recurse -File -Filter ([string]$fm['in_reply_to'] + '.md') -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($orig) {
            $ofm = Read-FrontMatter -Path $orig.FullName
            if ([string]$ofm['from'] -eq 'testbot') {
                & (Join-Path $PSScriptRoot '..\close.ps1') -Topic ([string]$fm['topic']) -Agent 'testbot' -Root $Root
            }
        }
    }
    exit 0
}
Start-Sleep -Milliseconds 800   # simulate work

$id = New-MessageId -From 'testbot'
$nowIso = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffzzz')
$body = @"
---
id: $id
topic: $($fm['topic'])
from: testbot
to: $($fm['from'])
type: reply
in_reply_to: $($fm['id'])
state: open
created: $nowIso
---

Test-stub reply: handled message $($fm['id']) successfully.
"@
$out = Join-Path (Join-Path (Join-Path (Join-Path $script:Root 'mailboxes') 'testbot') 'outbox') ($id + '.md')
Write-TextFile -Path $out -Content $body
& (Join-Path $PSScriptRoot '..\send.ps1') -File $out
