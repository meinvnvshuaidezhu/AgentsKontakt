# test-stub.ps1 - stable entry stub (PUSH-mode test stub (testbot)).
# The implementation lives in scripts\tests\test-stub.ps1. Root-level stubs keep the
# historical path alive for agent cards, schedulers, the tray exe and
# docs. See scripts\README.md before changing this layout.
& (Join-Path $PSScriptRoot 'tests\test-stub.ps1') @args
if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE } else { exit 0 }
