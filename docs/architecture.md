# Architecture, privacy, and recovery

## Design decisions

VeraData starts with a macOS utility and a framework-independent Swift library. SwiftUI provides native menus, forms, keyboard interaction, and system light and dark appearance. AppKit provides the palette window and pasteboard. The app registers a single global hotkey with the system. It does not need Accessibility or Input Monitoring permission. Native macOS controls also leave a direct path to PDFKit for later evidence work. A browser-first app would make deployment portable and would constrain cross-app invocation. A cross-platform desktop framework would add packaging and integration work before the core interaction is validated.

Safari AutoFill already covers information in Contacts. Text expanders such as Raycast Snippets already cover predefined text and short commands. VeraData’s initial differentiator is retrieving several known values from one named record while keeping its role and dates visible. The model uses straightforward records and stable IDs. A job owns its historical employer name and location. This avoids implying that updating an organization today can rewrite a past job. [Safari AutoFill](https://support.apple.com/guide/safari/autofill-info-from-contacts-ibrw1133/mac) · [Raycast Snippets](https://manual.raycast.com/snippets)

The local vault uses the same versioned JSON representation as the manual vault backup. For a personal dataset, that keeps the data inspectable and the restore path simple. A cached search index supports field labels, aliases, record context, and value text. Lookup is deterministic, folds case and diacritics, and ranks exact field or record labels and aliases ahead of broader token matches. Open-ended addresses rank ahead of otherwise equal historical ones. SQLite can be evaluated if real vaults eventually exceed the practical limits of full-file loading and atomic replacement.

VeraData supports [JSON Schema](https://json-schema.org/draft/2020-12/) for interchange validation. JSON Resume is useful for sharing selected work and education entries, while the vault also needs address history, profiles, custom fields, and shortcuts. An adapter is a better fit for future JSON Resume interoperability. Strict JSON keeps imports identical to exports for the first release. [JSON Resume schema](https://jsonresume.org/docs/guides/schema)

## Privacy model

The app does not make network requests or use accounts, analytics, external AI, or background synchronization. It holds the open vault in process memory. The default file is `~/Library/Application Support/VeraData/vault.json`. Newly created vault directories and files use modes `0700` and `0600`. The app and CLI share an interprocess lock. Updates check the opened revision or reviewed token before committing. A pending journal makes changes to the vault and preset files recoverable as one transaction. A failed validation leaves both unchanged.

The vault and backup files are plaintext. Treat access to the unlocked user session, readable backups, and synced export folders as access to the information. macOS disk encryption, user login protection, and encrypted backup destinations are the protection layers for this release. VeraData has no separate vault password or key-recovery process. Keep credentials and payment secrets in a tool designed to store them.

Copying puts the chosen representation on the macOS general pasteboard. Clipboard history, cross-device clipboard features, and other local applications may retain copied values. Returning to the previous app leaves pasting to the user. Selective export writes the fields checked in the export dialog and leaves the rest of the vault out of the file.

## Backup and recovery

1. Choose **File › Back Up Vault**. Save the readable JSON file somewhere protected and separate from the current vault.
2. In a fresh installation, choose **File › Restore Vault** and select the backup. Verify the number of profiles in the confirmation and choose **Replace Vault**.
3. Open a known record, check an original value and its formatted representation, and confirm that the preferred shortcut is available on the new Mac.

Manual restore replaces the vault and keeps the preset directory separate. Back up both for independent recovery. Use **File › Revision History** or `veradata history` to restore an earlier vault and its presets together. The restore itself retains the current state as a revision.

### Transaction recovery and external edits

The vault and adjacent preset files keep their existing layout. A private `vault.json.history` directory contains timestamped snapshots and a temporary pending journal. VeraData writes the journal before changing either data file. After interruption, the next app or CLI access finishes the same write under the lock before reading the state. Use the current VeraData version to finish any pending transaction before downgrading. Older clients do not participate in this recovery protocol.

The desktop checks for external changes and reloads when there is no open edit or review. If one is open, its draft is preserved and saving against a changed vault or preset fails. Close the draft and reopen the record or export review to work from the latest state. To keep draft changes, copy them before closing.

Revisions can contain private values that were later removed. History stores them locally with restrictive permissions and omits values from default previews. The default limit is 30 revisions, with a readable recovery point retained when available. Use the [CLI guide](cli.md#review-or-restore-a-revision) to change retention or prune history.

## Verification and roadmap

The core tests cover strict parsing, lossless round trips, search scope, exact aliases, decimal and identifier preservation, date formatting, historical addresses, selective disclosure, and conflicting writes. The portability check reads a vault independently with Python. The fictional demo makes it possible to assess the retrieval workflow without placing personal information in fixtures.

The next product decision depends on which workflow costs more time in practice. PDF evidence can connect an accepted field to a document revision and a highlighted passage. A browser adapter can preview a full employment section and fill approved values without auto-submitting. Safari and Windows delivery need independent platform validation. The read-only iPhone companion uses a manually exported snapshot of selected records. Both apps copy values for use in other apps. On iPhone, copied values stay on that device and expire from the pasteboard after two minutes.
