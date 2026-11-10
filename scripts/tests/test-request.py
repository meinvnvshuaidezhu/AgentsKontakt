#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Acceptance-test harness for AgentsKontakt (cross-platform, stdlib only).

The built-in test agent (testbot) originates a request TO the target agent so
the target's registered notification channel is verified end to end through
the real post-office path: delivery -> doorbell -> read -> reply.

    python3 scripts/test-request.py --to <your-name> [--root <path>]

The request instructs the target to reply with a body containing
ACCEPTANCE-OK and NO-REPLY (the test stub stays silent on NO-REPLY, so no
echo loop can start). Never target testbot itself.

Delivery guarantees mirror send.ps1: front-matter validation, duplicate-id
check, atomic rename into the target inbox, journal SEND entry - this is the
sanctioned cross-platform delivery path for acceptance requests.
"""

import argparse
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

FM_RE = re.compile(r'(?s)\A---\r?\n(.*?)\r?\n---\s*(?:\r?\n|$)')


def front_matter(path):
    fm = {}
    m = FM_RE.match(path.read_text(encoding='utf-8-sig'))
    if m:
        for line in m.group(1).splitlines():
            kv = re.match(r'^\s*([A-Za-z0-9_\-]+)\s*:\s*(.*?)\s*$', line)
            if kv:
                fm[kv.group(1).lower()] = kv.group(2).strip('\'"')
    return fm


def main():
    ap = argparse.ArgumentParser(description='AgentsKontakt acceptance-request sender')
    ap.add_argument('--to', required=True, help='registered name of the agent under test')
    ap.add_argument('--root', default='', help='shared root (default: auto-detect)')
    args = ap.parse_args()

    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parent
    if not args.root:
        while not (root / 'registry').is_dir() and root != root.parent:
            root = root.parent
    if args.to == 'testbot':
        sys.exit('refusing to send an acceptance request to testbot itself (echo loop)')
    card = root / 'registry' / (args.to + '.md')
    if not card.exists():
        sys.exit('target agent not registered: ' + args.to)
    fm = front_matter(card)
    if fm.get('name') != args.to or not fm.get('inbox'):
        sys.exit('registry card incomplete for: ' + args.to)
    inbox = root / fm['inbox']
    proc = inbox.parent / 'processing'
    if not inbox.is_dir():
        sys.exit('target inbox missing (run init first): ' + str(inbox))

    ts = datetime.now().astimezone()
    rand = format(ts.microsecond % 0x10000, '04x')
    mid = 'msg-' + ts.strftime('%Y%m%d-%H%M%S') + '-testbot-' + rand
    topic = 't-' + ts.strftime('%Y%m%d') + '-' + rand

    for d in (inbox, proc):
        if (d / (mid + '.md')).exists():
            sys.exit('duplicate message id: ' + mid)

    body = (
        '---\n'
        'id: ' + mid + '\n'
        'topic: ' + topic + '\n'
        'from: testbot\n'
        'to: ' + args.to + '\n'
        'type: request\n'
        'subject: ACCEPTANCE-TEST\n'
        'created: ' + ts.isoformat(timespec='milliseconds') + '\n'
        'state: open\n'
        '---\n'
        '\n'
        'ACCEPTANCE-TEST: this request verifies your registered notification\n'
        'channel end to end (see PROTOCOL 0 acceptance table). Steps for you:\n'
        '1. Note how you were woken - that is the inbound evidence for your channel.\n'
        '2. Reply now: type=reply, in_reply_to=' + mid + ', same topic, body must\n'
        '   contain ACCEPTANCE-OK and NO-REPLY (so this test does not bounce).\n'
        'Your reply DELIVERED proves the outbound leg; the wake itself proved inbound.\n'
    )

    outbox = root / 'mailboxes' / 'testbot' / 'outbox'
    outbox.mkdir(parents=True, exist_ok=True)
    tmp = outbox / (mid + '.md.tmp')
    tmp.write_text(body, encoding='utf-8', newline='')
    dest = inbox / (mid + '.md')
    os.replace(tmp, dest)  # atomic rename, same volume

    jdir = root / 'logs' / 'testbot'
    jdir.mkdir(parents=True, exist_ok=True)
    line = (ts.strftime('%Y-%m-%d %H:%M:%S') + ' | ' + 'SEND'.ljust(9)
            + '| ' + mid + ' | testbot->' + args.to + ' | topic=' + topic + ' | request\r\n')
    with (jdir / 'journal.log').open('a', encoding='utf-8', newline='') as f:
        f.write(line)

    # Ring the recipient's doorbell via the post-office router so PUSH targets
    # are spawned exactly like on a real send. Without any PowerShell the mail
    # simply waits in the inbox for self-check pickup (PULL-equivalent).
    route_ps = root / 'scripts' / 'core' / 'route.ps1'
    if not route_ps.exists():
        route_ps = root / 'scripts' / 'route.ps1'
    routed = False
    for ps in ('powershell', 'pwsh'):
        try:
            r = subprocess.run(
                [ps, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                 str(route_ps), '-File', str(dest), '-Root', str(root)],
                capture_output=True, timeout=60)
            for ln in r.stdout.decode(errors='replace').splitlines():
                # zh display keeps the token inline ("已派发 [DISPATCHED] ..."),
                # so match by containment, not line start.
                if any(tok in ln for tok in ('DISPATCHED', 'NOTIFY-FAILED', 'CLAIMED')):
                    print(ln)
            routed = (r.returncode == 0)
            break
        except FileNotFoundError:
            continue
    if not routed:
        print('note: no PowerShell available - acceptance mail waits in inbox for self-check pickup')

    print('DELIVERED ' + mid + ' -> ' + args.to)
    print('ACCEPTANCE-REQUEST ' + mid + ' topic=' + topic
          + ' - verify the inbound evidence for your channel, then reply per the instructions')
    return 0


if __name__ == '__main__':
    sys.exit(main())
