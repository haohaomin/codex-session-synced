# Codex Synced

English | [中文](README.md)

Codex Synced is a local Windows / macOS repair tool for Codex Desktop conversation history. It helps when conversations still exist on disk but disappear from the sidebar, show up as untitled "New conversation" rows, or sort with incorrect timestamps.

Codex Synced previews the local records that need repair, creates a backup, and repairs sidebar summary data in SQLite, `session_index.jsonl`, rollout file mtimes, and `.codex-global-state.json`. By default, recoverable interactive threads, including archived threads, and their rollout metadata are aligned to the root-level active `model_provider`. This restores history hidden after switching between OpenAI and custom providers. Cross-provider alignment can be disabled to use rollout metadata only as the SQLite source of truth.

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

1. Download `Codex-Synced-Windows-x64-1.3.0.msi` from the [latest GitHub Release](https://github.com/renhao12356578/codex-session-synced/releases/latest).
2. Quit Codex.
3. Install the MSI, then open `Codex Synced` from the Start menu.
4. Review pending changes, choose a backup mode, then apply the repair.
5. Reopen Codex and verify that local history is visible.

The Windows build is a full desktop app installer. It defaults to `%USERPROFILE%\.codex`, automatically detects the active state database directory, and the directory can be changed in settings. The Release also includes `Codex-Synced-Windows-x64-1.3.0.zip` for users who prefer a manually extracted app directory.

## macOS Download and Install

1. Download `Codex-Synced-macOS-1.3.0.dmg` from the [latest GitHub Release](https://github.com/renhao12356578/codex-session-synced/releases/latest).
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
