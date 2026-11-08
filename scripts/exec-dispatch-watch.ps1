# exec-dispatch-watch.ps1 - stable entry stub (exec-channel terminal-state watcher).
# The implementation lives in scripts\core\exec-dispatch-watch.ps1. Root-level stubs keep the
# historical path alive for agent cards, schedulers, the tray exe and
# docs. See scripts\README.md before changing this layout.
& (Join-Path $PSScriptRoot 'core\exec-dispatch-watch.ps1') @args
if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE } else { exit 0 }
