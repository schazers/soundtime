# Soundtime Diagnostics Runbook

Soundtime records a canonical schema-v2 event stream in memory, durable JSONL session files,
and Apple Unified Logging. The realtime audio callback only updates bounded C++ counters;
event construction, JSON encoding, disk writes, UI refreshes, and `Logger` projection happen
off the realtime thread.

## Reproduce And Mark An Incident

1. Reproduce the problem.
2. Choose **Help > Mark Diagnostic Incident** (or click **Mark Incident** in Development Console).
3. Leave Soundtime running for roughly 15 seconds so the post-incident window is captured.
4. Search Development Console using ordinary text or structured terms:
   - `delete`
   - `severity:severe`
   - `category:audio after:-30s`
   - `field.graphRevision:42`
5. Choose **Help > Export Diagnostic Bundle...**.

An incident covers 30 seconds before the mark and 15 seconds after it. Its session is pinned
against normal retention. Bundles are redacted by default and contain a manifest, JSONL events,
an automatic summary, performance/audio/operation/revision/config/build/system snapshots, and
references to recent Soundtime crash reports.

## Files On Disk

Sessions live in:

```text
~/Library/Logs/Soundtime/Sessions/
```

`Latest.json` names the latest event and metadata files. Each launch creates one append-only
`*.jsonl` event file and one atomic `*.meta.json` metadata file. A final partial JSONL line is
ignored during recovery. Soundtime retains 20 unpinned sessions or 100 MB, whichever limit is
reached first. Incident sessions are pinned.

Use **Help > Reveal Logs** to open this directory in Finder.

Manual and recovered-session bundles are retained in:

```text
~/Library/Logs/Soundtime/Bundles/
```

## Terminal Workflow

```bash
swift run SoundtimeLog list
swift run SoundtimeLog tail
swift run SoundtimeLog search 'severity:severe after:-5m'
swift run SoundtimeLog search 'field.graphRevision:42 delete'
swift run SoundtimeLog show SESSION_SUBSTRING
swift run SoundtimeLog incidents
swift run SoundtimeLog export SESSION_SUBSTRING ./Soundtime-Diagnostics.zip
```

Only use `--include-identifiable` when the reporter explicitly consents. Default exports remove
credential, transcript, user, project, email, and path fields and redact home-directory names.

## Event Authoring

- Reuse a catalog event name where one exists.
- Use `beginOperation` / `endOperation` for launch, import, playback, delete, paste, undo,
  export, transcription, and hydration work.
- Include `graphRevision` and `projectRevision` when available.
- Never call diagnostics from the realtime audio callback. Add a bounded counter/snapshot to the
  audio core and emit the structured event from the polling/control side.
- Never put API keys, transcript contents, or full user paths in messages.

## Recovery

If the previous session did not close cleanly, Soundtime offers to export diagnostics on the next
launch. Session metadata is marked complete only during normal termination. Recent `.ips` and
`.crash` report filenames are included in bundle manifests to connect OS crash evidence to the
event timeline without disclosing their full local paths.

## Verification

```bash
swift build
swift test --filter SoundtimeDiagnosticsCoreTests
swift run Soundtime --diagnostics-smoke
```

The core suite covers schema migration, typed fields, query parsing, privacy filtering,
concurrent append, truncated-line recovery, incomplete-session detection, and bundle contents.
