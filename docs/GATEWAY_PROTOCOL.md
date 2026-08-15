# iMM gateway outbox protocol (v1 beta foundation)

`iMarketMessage` writes a deliberately narrow hand-off for a local companion
that the user explicitly authorizes. The beta includes a real paired-self
sender: the iMM UI can save the first pairing and submit one queued message,
and `iMM-gateway --send` can process the same outbox. The UI also exposes
separate Service Management controls for the monitor and gateway companion.
Neither path accepts an arbitrary recipient, reads the Messages database or
Contacts, calls GitHub/`gh`/Codex, or uses an existing personal gateway. The
sender uses `/usr/bin/osascript` to ask Messages to send to the one stored
paired-self target; Apple Events permission and actual delivery remain user
responsibilities.

## Envelope

Every completed outbox file is named `<id>.json` and contains exactly these
three JSON keys:

```json
{"source":"market-message","id":"rule-<uuid>-<yyyyMMdd>","text":"..."}
```

The source is fixed to `market-message` and the v1 schema is represented by
the exact key set `source`, `id`, and `text` (there is no recipient field).
`text` is non-empty UTF-8 and is limited to 4,000 bytes. IDs are deterministic
for a rule and trading date and are restricted to a safe ASCII filename
alphabet. The filename must match the ID exactly. Unknown keys, unknown
sources, invalid IDs, oversized text, bad UTF-8/JSON, and mismatched filenames
are rejected and moved to the private `Quarantine` directory.

The producer writes a temporary file, applies mode `0600`, atomically moves it
to the final name, and keeps the outbox directory at mode `0700`. A consumer
must verify those modes (and reject symlinks) before reading. The consumer only
scans top-level `*.json` files; temporary and hidden files are ignored.

## Paired-self boundary

`GatewayPairingStore.firstSetup(target:)` is the only first-setup write path
for the paired-self target. The iMM UI exposes it as “首次配对”, refuses to
silently replace an existing target, and requires an explicit confirmation for
reset. It creates a `0600` file in a `0700` directory. The target is opaque
local setup state; it is not part of an envelope, is never discovered from
Contacts or Messages, and must not be printed or logged. A sender receives
only this stored target, so a queue file, CLI caller, or gateway service cannot
select an arbitrary recipient.

Before pairing, the consumer leaves outbox files untouched and reports
`waitingForPairing`. The shipped `PairedSelfIMessageSender` re-reads the
private pairing file before each send and passes the target and text as
separate arguments to a fixed AppleScript. `DryRunGatewaySender` remains a
no-I/O guard for tests and explicitly throws; it is never treated as a
successful send. A wrong-but-valid target is a real risk: `osascript` can exit
zero after Messages accepts the script even when Messages cannot deliver to
that target. A `sent`/submitted result therefore means “process accepted the
request”, not a delivery receipt; verify the paired target and Messages
conversation on the real device.

## ACK, idempotency, retry, and quarantine

ACK state is an application-private `0600` JSON file in a `0700` directory. It
records only the deterministic ID, status (`sent`, `failed`, `rejected`, or
`quarantined`), attempt count, timestamp, and a short generic error. Message
text, target values, credentials, and personal paths are not stored in ACKs or
status output.

For a valid envelope, the consumer:

1. checks the ACK record; an already `sent` ID is a duplicate and is removed
   without invoking the sender;
2. invokes the sender with the paired-self target only;
3. durably writes `sent` ACK state, then removes the outbox file.

Sender failures are recorded as `failed` and the file remains for the next
poll. After the configured retry limit (three attempts by default), the file
is moved to `Quarantine` and receives a `quarantined` ACK. Malformed or
permission-insecure files are isolated immediately. A deterministic ID makes
restarts and duplicate files idempotent at the companion boundary; a real
transport should also make its send operation idempotent where possible.

## Background registration and read-only plans

`GatewayInstallManager.dryRunPlan(...)` returns a reviewable launchd plist
string. `iMM-gateway --plan ...` prints the same plan. Neither operation writes
a file, calls `launchctl`, installs a LaunchAgent, or starts a service. The
checked-in `Config/com.imarketmessage.gateway.plist.example` is a template
only and intentionally uses `--dry-run`. The bundled App has the separate
user-facing action: after pairing, “启用 iMessage companion” registers
`com.imarketmessage.gateway.plist` through `SMAppService`; “停用 companion”
unregisters it. The monitor is a different `SMAppService` entry and can be
managed independently.

`iMM-gateway --dry-run ...` uses `GatewayOutboxPreview`, a read-only inspection
of already-existing files. It may report ready, duplicate, or rejected
envelopes, but it never creates an outbox/ACK/pairing/quarantine directory,
changes permissions, writes ACKs, moves or deletes files, or invokes a sender.
Its output is a preview, not a send result. Use it before an explicit UI
“发送一次” or `iMM-gateway --send` when reviewing a new outbox; `--send` is
the only CLI mode that consumes files. The old personal Codex gateway, if any,
is outside this product and is neither installed nor called by these paths.
