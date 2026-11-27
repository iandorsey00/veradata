# VeraData changelog

## 0.12.0 · 2026-11-27

- Use `.veradata` for both unencrypted and password-protected vaults. Finder displays the VeraData icon for these files. To open an existing `.veradatavault` file, rename its extension to `.veradata`.
- Verify fields while editing or from the record view by pasting source text or comparing a selection. VeraData saves the verification status with the record.
- Build the Mac app and bundled CLI with the macOS 27.2 SDK while keeping macOS 14 as the minimum version.

## 0.11.0 · 2026-11-26

- Use **Save Vault As…** to create an unencrypted or password-protected working vault with records, evidence, presets, settings, and revision history.
- Save a separate readable copy with **Back Up Records as JSON…**.
- Open newer stable versions on GitHub from **Update App…** in the macOS sidebar or VeraData menu.
- Move a built Mac app to Applications with `scripts/install-app.sh` and keep the previous build.

## 0.10.0 · 2026-11-26

- Create, open, lock, and back up separate encrypted .veradata working files containing records, presets, and evidence.
- View selected evidence PDFs and images on iPhone, with a select-all option for evidence under the checked records.
- Display and copy text lists with bullets, with plain text still available in the Format menu.
- Reuse same-record address fields in Mailing lines with placeholders for the recipient, street address, and unit.
- Add the **Work** address type and clarify how to enter international mailing lines.
- Attach a local PDF or image, mark a region, and check several record fields against it in one review.

## 0.9.0 · 2026-11-26

- Preview and apply a versioned change set across records and export presets in one recoverable transaction.
- Inspect, restore, and prune local revision history through the CLI. The desktop app also supports revision preview and restoration.
- Edit individual preset selections from the CLI. Whole-field selections follow current values, and selective list choices keep their fingerprint checks.
- The desktop app reloads external changes when its editing and review sheets are closed.
