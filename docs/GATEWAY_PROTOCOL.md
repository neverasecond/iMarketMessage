# iMM gateway outbox protocol (v1 beta foundation)

`iMarketMessage` writes a deliberately narrow hand-off for a separately
authorized local companion. This release is only a beta foundation: it has no
real sender, no pairing UI or pairing command, and no installation action. The
repository contains no Messages database reader, contact lookup, AppleScript
sender, `imsg` binary, or LaunchAgent installer. It can therefore be reviewed
and tested without sending any real message.

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

`GatewayPairingStore.firstSetup(target:)` is the only write path for the
paired-self target. It creates a `0600` file in a `0700` directory and refuses
to overwrite an existing pairing. The target is opaque local setup state; it is
not part of an envelope, is never discovered from Contacts or Messages, and
must not be printed or logged. A sender receives only this stored target, so a
queue file or caller cannot select an arbitrary recipient.

Before pairing, the consumer leaves outbox files untouched and reports
`waitingForPairing`. A real transport adapter is not shipped in this beta. If
one is separately reviewed and authorized on a real Mac, it must continue to
send only to this paired-self value. `DryRunGatewaySender` is a guard that
throws `unavailableInBeta`; it is never treated as a successful send.

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

## Background dry-run plan

`GatewayInstallManager.dryRunPlan(...)` returns a reviewable launchd plist
string. `iMM-gateway --plan ...` prints the same plan. Neither operation writes
a file, calls `launchctl`, installs a LaunchAgent, or starts a service. The
checked-in `Config/com.imarketmessage.gateway.plist.example` is a template
only and intentionally uses `--dry-run`.

`iMM-gateway --dry-run ...` uses `GatewayOutboxPreview`, a read-only inspection
of already-existing files. It may report ready, duplicate, or rejected
envelopes, but it never creates an outbox/ACK/pairing/quarantine directory,
changes permissions, writes ACKs, moves or deletes files, or invokes a sender.
Its output is a preview, not a send result. There is currently no pairing UI or
pairing command and no install action; a user must independently review,
authorize, and implement any future real transport and background installation
on the target Mac.
