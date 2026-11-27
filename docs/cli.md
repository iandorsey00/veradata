# VeraData command-line guide

Build once with `./scripts/build-app.sh`. The examples use `./scripts/veradata` from the VeraData checkout. You can also run the launcher by its absolute path from another directory. Run `./scripts/veradata --help` for command syntax.

VeraData uses the desktop vault by default. Pass `--vault PATH` to work with another file. For profile-scoped commands, use `--profile` with an ID or name. Leaving it out selects the first profile. Commands that show or change records use record IDs.

## Try it with fictional data

```sh
work="$(mktemp -d)"
vault="$work/vault.json"
./scripts/veradata profile create "Demo" --id demo --vault "$vault"
./scripts/veradata record add --profile demo --id contact --kind contact \
  --label 'Alex Example' --set 'name=Alex Example' \
  --set 'email=alex@example.com' --vault "$vault"
./scripts/veradata record add --vault "$vault" --profile demo --id job \
  --kind employment --label 'Current job' --fields - <<'JSON'
{
  "employer": "Example Company",
  "title": "Operations Analyst",
  "startDate": "2024-05",
  "endDate": "Present",
  "responsibilities": [
    "Documented intake procedures.",
    "Reviewed workflow exceptions."
  ]
}
JSON
./scripts/veradata profiles --vault "$vault"
./scripts/veradata records --profile demo --vault "$vault"
./scripts/veradata record show job --profile demo --vault "$vault"
```

## Find and edit data

```sh
./scripts/veradata search 'start year' --profile demo --record job --vault "$vault"
./scripts/veradata get job startDate --profile demo --vault "$vault"
./scripts/veradata get job /startDate --representation Year --profile demo --vault "$vault"
./scripts/veradata record update job --set 'title=Senior Operations Analyst' \
  --profile demo --vault "$vault"
```

Search returns metadata with record IDs, field paths, and representation labels. Use `--values` to include matched values, or `get` to retrieve just one. `get` accepts exact field keys, search paths, and stored aliases. Add `--copy` to copy the result to the macOS clipboard. `current today` and `current timestamp` use the Mac’s clock.

To render a saved **Mailing lines** template from the terminal, use `get RECORD formatted --representation 'Rendered address'`. The raw `formatted` field and selective JSON exports preserve the template.

Use `record update --fields FILE` to merge a JSON object into a record. Arrays, numbers, and explicit null values keep their types. Use `--set KEY=TEXT` for text, or repeat `--unset KEY` to omit fields entirely. For values you prefer to keep out of shell history, use `--fields FILE` or `--fields -`. Supply `--aliases FILE` to replace the complete alias map with a JSON object such as `{";mail":"email"}`. Removing a field also removes its aliases unless you provide a new map.

`profile rename PROFILE NAME` changes the profile name while keeping its ID. `profile delete PROFILE --yes` and `record delete RECORD --yes` explicitly confirm deletion. Keep at least one profile. `shortcut` reads the saved hotkey setting. Supply `space`, `j`, `k`, or `off` to change it. The app reloads terminal changes after any open edit or review sheet closes.

## Preview and apply an import

Use a VeraData backup, transfer, structured selection, import file, or plain JSON object. If the input contains several profiles, specify `--source-profile ID_OR_NAME`.

```sh
./scripts/veradata import examples/record-import.json --profile demo --vault "$vault"
./scripts/veradata import examples/record-import.json --profile demo --vault "$vault" --apply
```

The preview lists what would be added, updated, or skipped. By default, matching records are skipped. Use `--on-match update` to merge incoming fields into the exact ID or unique matching record, or `--on-match add` to create separate records. An ambiguous update fails before any write. Use `record update` with the intended ID to resolve it. `--apply` commits the validated changes.

## Create or update an export preset

```sh
./scripts/veradata selection --resume recommended --profile demo --vault "$vault" \
  > "$work/selection.json"
./scripts/veradata export --selection "$work/selection.json" --vault "$vault"
./scripts/veradata preset save demo-resume --selection "$work/selection.json" --vault "$vault"

./scripts/veradata presets --vault "$vault"
./scripts/veradata export --preset demo-resume --vault "$vault"
./scripts/veradata export --preset demo-resume --format structured --vault "$vault"
```

`selection --resume` accepts `standard`, `recommended`, or `all`. Use `--contact RECORD` if the profile has several eligible contacts. Repeat `--exclude RECORD` to omit records from this selection. **All** includes unclassified custom records for review. Assign each a supported section or remove it from the JSON before exporting.

Selections contain record IDs and field choices. A field set to `true` exports the whole value. Use an array of zero-based indices to choose list items. Record order comes from the array. Supported formats are `resume`, `structured`, and `flat` for one record of scalar fields. Custom résumé sections are `skills`, `projects`, `languages`, and `certifications`.

```json
{
  "profile": "demo",
  "format": "structured",
  "records": [
    {"id": "job", "fields": {"title": true, "responsibilities": [0]}}
  ]
}
```

To revise a saved preset, run `preset show NAME` and redirect the selection to a file. It works even when the vault has changed and the preset is stale. Edit the selection, run `export --selection FILE` to review it against current values, then run `preset save NAME --selection FILE --replace`. This refreshes the reviewed list fingerprints. `preset delete NAME --yes` removes the preset.

VeraFlow accepts the default résumé export directly on stdin. The `structured` override outputs the selected source fields for other uses. [VeraFlow résumé pipeline](../README.md#run-from-the-terminal)

## Back up, restore, or transfer to iPhone

```sh
(umask 077; ./scripts/veradata backup --vault "$vault" > "$work/backup.json")
(umask 077; ./scripts/veradata export-phone --profile demo --record contact \
  --vault "$vault" > "$work/iphone.json")
./scripts/veradata restore "$work/backup.json" --vault "$work/restored.json" --yes
```

Repeat `--record` for specific iPhone records or use `--all` for every record in the selected profile. To select records across profiles, repeat `--pick PROFILE_ID:RECORD_ID`. The CLI phone export includes records only. To include evidence, select documents in the Mac app’s **Export for iPhone** dialog. A backup contains every profile and the shortcut setting. Back up the vault’s adjacent `vault.json.export-presets` directory separately to retain presets. Treat backup and export files as readable personal data.

To roll back the app, build the previous release tag in a separate checkout. The vault still uses schema version 1. Older builds may reject newer preset versions. Recover any pending transaction in the current version before rolling back, and retain a copy of the preset directory. Avoid running mixed versions against the same vault.

## Review and apply a batch

A change set can edit several records and a saved export preset together. Use the profile and record IDs from `profiles` and `records`. The [fictional change set](../examples/change-set.json) works with the demo and the `demo-resume` preset created in this guide. Its shape is documented in the [change-set schema](../schema/change-set-v1.schema.json).

```sh
./scripts/veradata apply examples/change-set.json --vault "$vault" --human
./scripts/veradata apply examples/change-set.json --vault "$vault" --apply --expect PREVIEW_TOKEN
```

Replace `PREVIEW_TOKEN` with the token printed by the preview. The token covers the current vault, presets, and change set. If anything changes, preview again. `--commit` is accepted as an alias for `--apply`. Both accept `-` in place of the filename for stdin.

Operations run in order. `record.update` merges typed JSON values under `fields`, uses `unset` to remove named fields, and optionally changes `label`. Omitted fields keep their values. `preset.update` targets a named preset and a record. A field choice of `true` selects the whole current value, `false` excludes the field, and an array chooses specific zero-based list items. You can assign a custom résumé `section`, set a zero-based `position`, or set `excludeRecord` to remove the record from the preset. Repeating a selective list choice explicitly reviews its current items.

For one preset change, use the same preview and apply flow directly:

```sh
./scripts/veradata preset update demo-resume --record contact --include headline --vault "$vault"
./scripts/veradata preset update demo-resume --record contact --include headline \
  --vault "$vault" --apply --expect PREVIEW_TOKEN
```

Repeat `--include` or `--exclude` for fields. Use `--items FIELD=0,2`, `--section projects`, `--position 0`, or `--remove-record` as needed. `--section none` clears a section when allowed by the selected format. Full selection documents still work with `preset show`, `export --selection`, and `preset save`.

Previews print JSON by default. `--human` prints a readable summary. Values are omitted by default, and `--show-values` reveals changed values intentionally. Use `--json-errors` for JSON diagnostics on stderr. Exit status is 0 for success, 1 for a failed command, and 3 when a current write or stale preview conflicts. Retry a busy write or review fresh state before applying a stale change.

## Review or restore a revision

```sh
./scripts/veradata history --vault "$vault"
./scripts/veradata history show REVISION_ID --vault "$vault" --human
./scripts/veradata history restore REVISION_ID --vault "$vault" --human
./scripts/veradata history restore REVISION_ID --vault "$vault" --apply --expect PREVIEW_TOKEN
```

Each entry describes a mutation and stores the state immediately **before** it. `history show` compares that state with the current state. Use `--against REVISION_ID` to compare with a different snapshot. Restore previews show the changes that would be applied. An applied restore also saves the state it replaces.

The default retention is 30 revisions. `history retention` reports the configured limit. To change it, use `history retention --keep COUNT --apply`. To prune now without changing the ongoing limit, use `history prune --keep COUNT --apply`. VeraData retains a readable recovery revision if the other retained entries cannot be restored. Review a prune before adding `--apply`.

History is local and may still contain values removed from your vault. Prune it explicitly when appropriate and keep an independent backup. Existing vaults and presets load in place. Whole-field choices from older presets also track current values. Selective lists retain their fingerprint checks and need review when the list changes. Close and reopen an outstanding app edit or export review if it conflicts with a CLI update.


## Work with an encrypted vault

```sh
./scripts/veradata vault encrypt "$HOME/Documents/Work.veradata" --vault /path/to/vault.json
./scripts/veradata profiles --vault "$HOME/Documents/Work.veradata"
```

Pass the path explicitly with `--vault` to use a complete `.veradata` vault saved in the Mac app. Unencrypted vaults open directly. For a password-protected vault, the terminal prompts for the password without echoing it. Standard input stays available for imports and change sets. The `backup` command emits the complete file in its original format. Redirect the output to a fresh `.veradata` filename with restrictive permissions, then open that file as its own vault to recover. On the Mac, **Save Vault As…** can also choose a different protection format.
