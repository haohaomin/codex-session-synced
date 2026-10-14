# Codex Synced

## 1.9.0: Software update discovery

[1.9.0 release notes](docs/release/v1.9.0-en.md) · [Download 1.9.0](https://github.com/haohaomin/codex-session-synced/releases/tag/v1.9.0)

macOS and Windows now offer **Settings → Software Update**: manual checks, opt-in launch checks (off by default), installed/latest versions and plain-text release notes. Checks read only this repository's stable GitHub release metadata, validate numeric versions, release-page and platform-package URLs, and reject drafts, prereleases, incomplete assets or unexpected sources. No packages are downloaded. Automatic failures are quiet; manual failures show an error, never “up to date”.

When an update is available, **Open Download Page** asks for confirmation before opening that version's release page. Download the macOS DMG, Windows x64 MSI or portable ZIP yourself. Finish repairs, quit Codex Synced normally and retain the old app and backups before installing. Extract portable ZIPs into a new directory, not over running files. Relaunch and verify the version and data.

**This is not automatic installation.** Packages do not yet have independent updater signatures; SHA256SUMS are not signatures. The checker does not download/execute packages, kill processes or modify `.codex`, Provider configuration, databases or chats. Opening the page does not mean an update succeeded. Signed installation, replacement, restart handshakes and rollback remain future work. [Plan and acceptance boundaries](docs/software-update-plan.md).

English | [中文](README.md)

## 1.5.0: Provider-Switch Diagnostics & Safe Backups

This release unifies provider-switch visibility repair, paginated-risk warnings, and backup boundaries into one **diagnose → preview → back up → verify** workflow. Paginated rollout headers are still never rewritten silently; cases requiring `history_base` recalculation stop for manual review.

[1.5.0 release notes](docs/release/v1.5.0-en.md) · [Download 1.5.0](https://github.com/renhao12356578/codex-session-synced/releases/tag/v1.5.0)

[1.6.0 release notes](docs/release/v1.6.0-en.md) · [Download macOS 1.6.0](https://github.com/haohaomin/codex-session-synced/releases/tag/v1.6.0)

[1.7.0 release notes](docs/release/v1.7.0-en.md) · [Download Codex Synced 1.7.0](https://github.com/haohaomin/codex-session-synced/releases/tag/v1.7.0)

## 1.8.1: Unified writer-protection patch

macOS now also recognizes a standalone `codex-app-server` process before any write, matching Windows. Desktop, CLI, and app-server writers always fail closed; the tool never kills a process.

[1.8.1 release notes](docs/release/v1.8.1-en.md) · [Download Codex Synced 1.8.1](https://github.com/haohaomin/codex-session-synced/releases/tag/v1.8.1)

## 1.8.0: Complete cross-platform design parity

1.8.0 closes the remaining consistency gaps after 1.7.0: Windows persists the language choice, detects Desktop/CLI/app-server writers, requires an unambiguous auto-discovered state database for Chat Repair, scopes unknown-file blocking to the affected directory, and verifies the entrypoint on the SQLite trial copy before committing. macOS performs the same trial-entrypoint check.

[1.8.0 release notes](docs/release/v1.8.0-en.md) · [Download Codex Synced 1.8.0](https://github.com/haohaomin/codex-session-synced/releases/tag/v1.8.0)

## 1.7.0: Unified Windows / macOS repair design

This release brings both platforms to the same repair workflow and safety model:

- Windows and macOS both provide **Chat Repair** with read-only lineage diagnosis, minimal `rollout_path` repair, and conditional rollback.
- Paginated Provider repair is a separate second-stage operation on both platforms: trial on copies first, then update the header, `history_base`, turn offsets, and projection offsets together.
- Both platforms use the same **diagnose → preview → back up → write → verify** flow, risk levels, Codex-writer check, and post-restart manual acceptance boundary.
- Windows persists the language choice, detects Desktop/CLI/app-server writers, and scopes unknown rollout-file blocking to the affected directory.

[Unified design specification](docs/unified-design.md) · [1.7.0 publish and acceptance plan](docs/release/v1.7.0-publish-plan.md)

- **Layered provider safety**: legacy-format threads remain eligible for safe alignment; paginated Provider mismatches are shown separately and are not presented as body repairs.
- **WAL-consistent backups**: lightweight backups retain live SQLite/WAL/SHM files and create SQLite Backup API snapshots for present `state_*`, `thread_history_*`, and `logs_*` databases.
- **Scoped unknown-file blocking**: temporary, repair, and backup artifacts are ignored; an unrecognized rollout only blocks chats in its own directory.
- **Unified risk UI**: the pending-repair and chat-repair pages now use the same status, risk, and verification-boundary cards.
- **Windows paginated parity**: Windows now includes the independent lineage, `history_base`, `thread_turns`, and projection repair planner; ordinary repair and paginated confirmation remain separate. The Windows build, self-test, and real-copy acceptance must pass before this path is included in a release artifact. See the [Windows paginated repair plan](docs/windows-paginated-safety-plan.md).

## 1.6.0: safe paginated Provider repair

The second-stage paginated repair path is now implemented behind an explicit confirmation flow and remains separate from the ordinary sidebar repair. See the [implementation plan](docs/paginated-provider-repair-plan.md).

- Builds a global physical-branch index and fails closed on duplicate IDs, multiple history databases, missing parents, ambiguous tips, or unexplained boundaries.
- Recalculates descendant `history_base.end_byte_offset`, `thread_turns` offsets, and the projection cursor from the actual first-line byte delta, without concatenating or rebuilding message bodies.
- Trials the complete change on SQLite Backup API snapshots and uniquely isolated rollout copies before touching live files.
- Uses compare-and-swap metadata checks, body hashes, and backup recovery; it never kills a running Codex process.
- Shows paginated diagnostics directly in the UI and offers only fully validated repairs in the separate second-stage section.

The full test suite and Release build pass. After applying a repair, reopen and restart Codex and manually compare message order, omissions, duplicates, and project ownership.

## 1.4.0: Chat Diagnosis & Entrypoint Repair (historical release)

The new **Chat Repair** page addresses paginated chats whose JSONL files still exist but whose logical thread points to an older branch. It is separate from sidebar repair. Both macOS and Windows now provide read-only lineage diagnosis, minimal entrypoint repair, and guarded rollback. Windows paginated Provider offset repair also has its own explicit confirmation flow and never runs through ordinary Provider alignment.

[1.4.0 release notes](docs/release/v1.4.0-en.md)

- Read-only scanning follows the original `history_base` chain, distinguishing logical thread IDs from physical branch IDs. It never selects a tip by modification time.
- Ambiguous tips, cycles, duplicate physical IDs, missing parents, malformed JSON, ordinal gaps, byte-boundary mismatches, symlinks and unknown formats block automatic repair. Counts cover message records within effective inheritance boundaries, not client turns.
- Quit Codex Desktop and CLI/app-server before writes. Review and confirm one chat at a time. Only `threads.rollout_path` changes; all other columns, including ID, title, project, `cwd`, section and archive state, remain intact. No history-database rewrite, message reconstruction or concatenation.
- SQLite Backup API captures committed WAL pages. Original branch files are copied too. The update is trialled on a database copy before a checked transaction touches the live database. Stale previews are rejected.
- Rollback reverses only that entrypoint, never restores the whole database. Changed metadata, files or branches block rollback to protect subsequent activity. Records live in `history-entrypoint-backups/` under the selected Codex Home and are not auto-pruned. A durable record is written before commit and can represent an uncommitted attempt, not proof of success.
- The macOS sidebar Provider repair now leaves JSONL headers containing `history_mode: paginated`, `history_base` or `ordinal` untouched, protecting inherited byte offsets. Legacy-format Provider repair is unchanged.
- **Paginated Provider warnings**: scans show SQLite/rollout Provider mismatches in paginated threads as review items instead of presenting them as completed history repairs.

Choose **Chat Repair → Read-only Scan**, review the current and proposed paths, quit Codex, then confirm **Back Up & Repair Entrypoint**. The selected SQLite directory must contain exactly one `state_*.sqlite`; configure paths in Settings when necessary. Anomalies require manual investigation, with no force-repair option.

**Verification boundary:** automated checks cover source-file SHA-256 preservation, ordinal and byte-boundary consistency, preservation of every non-entrypoint SQLite field and database integrity. The copy trial tests the database change, **not isolated client `thread/read` / paginated message-body equivalence or desktop restart persistence**. Reopen the original chat, compare content/order/missing or duplicate messages, then quit and restart Codex to verify persistence and project association. “Entrypoint repaired” does not mean full conversation acceptance. Offset anomalies, including a 50-byte discrepancy, are reported without modification.

Backups contain private conversations and database metadata. Protect them like the originals. Present state, history, and log databases receive WAL-consistent snapshots, but no atomic cross-database transaction is claimed. Regression tests use isolated temporary fixtures covering edited replacements, metadata and source preservation, WAL backup, scoped unknown files, stale previews, broken/ambiguous branches, invalid offsets, transaction rollback and protection of later changes.

See the [implementation and validation record](docs/history-repair-validation.md) (Chinese) for build commands and outstanding acceptance checks.

Codex Synced is a local Windows / macOS repair tool for Codex Desktop conversation history. It helps when conversations still exist on disk but disappear from the sidebar, show up as untitled "New conversation" rows, or sort with incorrect timestamps.

Codex Synced previews the local records that need repair, creates a backup, and repairs sidebar summary data in SQLite, `session_index.jsonl`, rollout file mtimes, and `.codex-global-state.json`. By default, recoverable interactive threads, including archived threads, and rollout metadata that can be safely rewritten are aligned to the root-level active `model_provider`. This restores history hidden after switching between OpenAI and custom providers. Provider mismatches in paginated rollouts are shown as a separate review item and are not rewritten before their `history_base` byte boundaries are recalculated. Cross-provider alignment can be disabled to use rollout metadata only as the SQLite source of truth.

## What's New in 1.3.0

Compared with 1.2.7, this release adds the following fixes and compatibility improvements:

- **Correct state database selection**: checks both the `.codex` root and its `sqlite` subdirectory, using database and WAL/SHM modification times so a stale nested database does not hide an active root database.
- **Provider alignment for archived history**: includes archived interactive threads and updates both SQLite and rollout session metadata to restore archived history hidden after a provider switch.
- **More complete index rebuilding**: retains archived and internal thread records with existing local rollout files in `session_index.jsonl`, keeping IDs unique.
- **Support for the current title field**: prefers nonempty `threads.name` values and updates both `name` and `title` when repairing titles.
- **Recovery of corrupted titles**: detects tool-call fragments in generated titles and recovers titles from the conversation preview or first user message.
- **Creation timestamp repair**: detects records where `created_at > updated_at` and uses rollout timestamps and available recency timestamps to correct creation times, supporting second and millisecond fields.
- **Lower memory use during first-line rewrites**: streams rollout header replacement while preserving subsequent message bytes, avoiding loading an entire large conversation during the rewrite.
- **More reliable macOS packaging**: extends the Finder layout timeout for DMG creation to 300 seconds.

Regression coverage was also added for database selection, archived threads, corrupted titles, creation timestamps, and index retention. Windows self-tests and release builds for both platforms passed.

[Full release notes](docs/release/v1.3.0-en.md) · [Download 1.3.0](https://github.com/renhao12356578/codex-session-synced/releases/tag/v1.3.0)

## Windows Download and Usage

1. Download `Codex-Synced-Windows-x64-1.8.1.msi` from the [latest GitHub Release](https://github.com/haohaomin/codex-session-synced/releases/latest).
2. Quit Codex.
3. Install the MSI, then open `Codex Synced` from the Start menu.
4. Review pending changes, choose a backup mode, then apply the repair.
5. For paginated Provider cases or hidden follow-up messages, open **Chat Repair**, run a read-only scan, and confirm paginated or entrypoint repair one chat at a time.
6. Reopen and restart Codex, then verify message content, order, omissions, duplicates, and project ownership.

The Windows build is a full desktop app installer. It defaults to `%USERPROFILE%\.codex`, automatically detects the active state database directory, and the directory can be changed in settings. The Release also includes `Codex-Synced-Windows-x64-1.8.1.zip` for users who prefer a manually extracted app directory.

## macOS Download and Install

1. Download `Codex-Synced-macOS-1.8.1.dmg` from the [latest GitHub Release](https://github.com/haohaomin/codex-session-synced/releases/latest).
2. Open the DMG.
3. Drag `Codex Synced.app` into `Applications`.
4. On first launch, if macOS blocks the app, right-click it in Finder, choose `Open`, and confirm.
5. Quit Codex before repairing or restoring local history.

### If macOS says the app is damaged

The current version is not Apple-notarized yet. If the DMG came from this repository's Release page, remove its quarantine attribute after verifying the download:

```bash
xattr -dr com.apple.quarantine "/Applications/Codex Synced.app"
```

Avoid globally disabling Gatekeeper.

## Highlights

- Detects the active Codex provider and local state database automatically.
- Compares state databases in both the `.codex` root and `.codex/sqlite`, including WAL/SHM activity, and selects the database that is actually current.
- Aligns both active and archived interactive threads in SQLite and rollout session metadata.
- Supports the current `threads.name` and millisecond timestamp fields, including timezone-migration rows where `created_at` is later than `updated_at`.
- Streams first-line rollout rewrites without loading the full conversation into memory.
- Previews SQLite provider mismatches, sidebar titles, timestamps, rollout mtimes, `session_index.jsonl`, and global UI state fixes.
- Creates a lightweight or full backup before writing.
- Restores from previous backups when needed.

## Safety

Codex Synced does not modify OAuth tokens, API keys, third-party URLs, provider settings, or message bodies. It only repairs local history visibility data after you review the preview and choose a backup mode.
