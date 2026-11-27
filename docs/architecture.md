# Architecture, privacy, and recovery

## Design decisions

VeraData starts with a macOS utility and a framework-independent Swift library. SwiftUI provides native menus, forms, keyboard interaction, and system light and dark appearance. AppKit provides the palette window and pasteboard. The app registers a single global hotkey with the system. It does not need Accessibility or Input Monitoring permission. A browser-first app would make deployment portable and would constrain cross-app invocation. A cross-platform desktop framework would add packaging and integration work before the core interaction is validated.

Safari AutoFill already covers information in Contacts. Text expanders such as Raycast Snippets already cover predefined text and short commands. VeraData’s initial differentiator is retrieving several known values from one named record while keeping its role and dates visible. The model uses straightforward records and stable IDs. A job owns its historical employer name and location. This avoids implying that updating an organization today can rewrite a past job. [Safari AutoFill](https://support.apple.com/guide/safari/autofill-info-from-contacts-ibrw1133/mac) · [Raycast Snippets](https://manual.raycast.com/snippets)

The local vault uses the same versioned JSON representation as the manual vault backup. For a personal dataset, that keeps the data inspectable and the restore path simple. A cached search index supports field labels, aliases, record context, and value text. Lookup is deterministic, folds case and diacritics, and ranks exact field or record labels and aliases ahead of broader token matches. Open-ended addresses rank ahead of otherwise equal historical ones. SQLite can be evaluated if real vaults eventually exceed the practical limits of full-file loading and atomic replacement.

VeraData supports [JSON Schema](https://json-schema.org/draft/2020-12/) for interchange validation. JSON Resume is useful for sharing selected work and education entries, while the vault also needs address history, profiles, custom fields, and shortcuts. An adapter is a better fit for future JSON Resume interoperability. Strict JSON keeps imports identical to exports for the first release. [JSON Resume schema](https://jsonresume.org/docs/guides/schema)

## Privacy model

The app does not make network requests or use accounts, analytics, external AI, or background synchronization. It holds the open vault in process memory. The default file is `~/Library/Application Support/VeraData/vault.json`. Newly created vault directories and files use modes `0700` and `0600`. The app and CLI share an interprocess lock. Updates check the opened revision or reviewed token before committing. A pending journal makes changes to the vault and preset files recoverable as one transaction. A failed validation leaves both unchanged.

Plain JSON vaults and their backups are plaintext. macOS disk encryption, user login protection, and encrypted backup destinations protect those files. Treat access to the unlocked user session, readable backups, and synced export folders as access to the information. Encrypted vaults use a separate password with no key-recovery process. Keep credentials and payment secrets in a tool designed to store them.

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

A browser adapter can preview a full employment section and fill approved values without auto-submitting. Safari and Windows delivery need independent platform validation. The read-only iPhone companion uses a manually exported snapshot of selected records. Both apps copy values for use in other apps. On iPhone, copied values stay on that device and expire from the pasteboard after two minutes.

## Field evidence

A Mac evidence mark references an immutable local copy of a PDF or image, the page and normalized rectangle, and a separate fingerprint for every field checked against the area. VeraData keeps the user’s data as entered. A mark records a manual comparison with that source. VeraData checks the file fingerprint when it opens the document. Copies are stored by SHA-256 digest beside the vault in `vault.json.evidence`, with private file permissions. The same document takes one copy even when used by multiple marks. The original remains outside VeraData and can be moved or edited independently.

Revision history includes marks and restores their links. Removing a mark leaves the document copy available to older revisions. An independent vault backup includes the marks, and restoring the source documents requires the adjacent evidence folder as well. To restore a differently named vault, name the folder after the new vault filename followed by `.evidence`. The folder contains readable original documents. Keep it private like the vault and presets. Record imports and ordinary exports omit evidence links.

## Encrypted working files

A `.veradata` file stores one authenticated snapshot. The version 1 binary header contains a format signature and a random 16-byte salt. CommonCrypto derives a 256-bit key using PBKDF2-HMAC-SHA256 (600,000 rounds). CryptoKit uses AES-256-GCM with a fresh nonce on each write and authenticates the header as associated data. The encrypted payload contains the current vault JSON, presets, revisions, and deduplicated original evidence bytes. Pruning revisions also removes evidence bytes if no current record or retained revision references them. Selective exports remain independent and readable where their formats call for it.

The app remembers the last encrypted file's path on the Mac. It derives a key on unlock and does not store the password in settings or a keychain. Different files can use different passwords. Migration writes a new encrypted file without altering the JSON vault or importing its existing local revision history. **Back Up Vault** copies the already encrypted bytes to a new file. Copies are protected by the password used for the working file.

The encrypted backend uses `NSFileCoordinator` inside the system iCloud Drive and cloud provider folders and a per-file interprocess lock for local files. It checks the previously read file before replacing it, and declines writes while macOS reports unresolved document conflicts. The single file eliminates syncing independently written sidecars. Cloud providers may still produce conflicts or separate copies after offline edits. VeraData leaves such copies for the user to review and does not merge them. Use a single writer across devices and let sync finish between sessions. These are file sync semantics, with no VeraData-hosted sync service.

To return to VeraData 0.9, use the preserved JSON vault from before migration. Edits made only in the encrypted working file stay in that file. Keep an encrypted backup and the current app available to reopen it.
