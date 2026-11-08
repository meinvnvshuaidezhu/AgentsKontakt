# cleanup.ps1 - stable entry stub (orphan tmp / requeue / rotation).
# The implementation lives in scripts\core\cleanup.ps1. Root-level stubs keep the
# historical path alive for agent cards, schedulers, the tray exe and
# docs. See scripts\README.md before changing this layout.
& (Join-Path $PSScriptRoot 'core\cleanup.ps1') @args
if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE } else { exit 0 }
