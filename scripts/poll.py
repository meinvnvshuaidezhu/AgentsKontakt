#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Universal poll doorbell for AgentsKontakt (cross-platform, stdlib only).

An agent that registers the poll channel schedules this script in its OWN
environment (cron / systemd timer / Windows Task Scheduler / app-internal
timer / hook - anything that can run a command once a minute):

    python3 scripts/poll.py --agent <name> [--notify "<command>"] [--root <path>]

Behavior:
  1. Locate the shared root (default: parent of the scripts/ dir this file
     lives in) and the agent's inbox: <root>/mailboxes/<agent>/inbox.
  2. Diff current inbox message ids against logs/<agent>/poll-known.txt.
  3. On new arrivals: append a POLL entry to logs/<agent>/journal.log (same
     format as the PowerShell post office) and run the optional --notify
     command so the agent can wake itself however it can - {agent} {count}
     {ids} {root} placeholders are substituted, e.g. a desktop toast, a local
     API call to its host app, a marker file for its own hook, an IM ping.
  4. Exit code: 1 = new mail (or notify failure), 0 = nothing new.

Pure standard library; runs unchanged on Windows / macOS / Linux.
"""

import argparse
import subprocess
import sys
from datetime import datetime
from pathlib import Path


def main():
    ap = argparse.ArgumentParser(description='AgentsKontakt poll doorbell')
    ap.add_argument('--agent', required=True, help='your registered name')
    ap.add_argument('--root', default='', help='shared root (default: auto-detect)')
    ap.add_argument('--notify', default='',
                    help="command to run on new mail; placeholders {agent} {count} {ids} {root}")
    args = ap.parse_args()

    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parent.parent
    inbox = root / 'mailboxes' / args.agent / 'inbox'
    if not inbox.is_dir():
        return 0
    ids = sorted(p.stem for p in inbox.glob('*.md'))
    if not ids:
        return 0

    logs = root / 'logs' / args.agent
    logs.mkdir(parents=True, exist_ok=True)
    known_file = logs / 'poll-known.txt'
    known = set()
    if known_file.exists():
        known = set(known_file.read_text(encoding='utf-8').split())
    new = [i for i in ids if i not in known]
    if not new:
        return 0

    # remember the current inbox set: new arrivals fire once, claimed mail is
    # pruned automatically (requeued mail therefore fires again - intended)
    known_file.write_text('\n'.join(ids) + '\n', encoding='utf-8')

    # journal entry, byte-compatible with the PowerShell post office format
    journal = logs / 'journal.log'
    line = (datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            + ' | ' + 'POLL'.ljust(9) + '| new mail: ' + ', '.join(new) + '\r\n')
    with journal.open('a', encoding='utf-8', newline='') as f:
        f.write(line)

    if args.notify:
        cmd = (args.notify
               .replace('{agent}', args.agent)
               .replace('{count}', str(len(new)))
               .replace('{ids}', ' '.join(new))
               .replace('{root}', str(root)))
        try:
            # CREATE_NO_WINDOW keeps the notify child (cmd /c + powershell)
            # console-less when poll.py itself runs under pythonw / Task Scheduler
            subprocess.run(cmd, shell=True, timeout=30, check=False,
                           creationflags=0x08000000 if sys.platform == 'win32' else 0)
        except Exception as e:  # notify must never kill the poll loop
            sys.stderr.write('poll: notify failed: %r\n' % (e,))
    return 1


if __name__ == '__main__':
    sys.exit(main())
