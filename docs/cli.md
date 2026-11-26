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

Use `record update --fields FILE` to merge a JSON object into a record. Arrays, numbers, and explicit null values keep their types. Use `--set KEY=TEXT` for text, or repeat `--unset KEY` to omit fields entirely. For values you prefer to keep out of shell history, use `--fields FILE` or `--fields -`. Supply `--aliases FILE` to replace the complete alias map with a JSON object such as `{";mail":"email"}`. Removing a field also removes its aliases unless you provide a new map.

`profile rename PROFILE NAME` changes the profile name while keeping its ID. `profile delete PROFILE --yes` and `record delete RECORD --yes` explicitly confirm deletion. Keep at least one profile. `shortcut` reads the saved hotkey setting. Supply `space`, `j`, `k`, or `off` to change it. Reopen the app to pick up terminal changes to an already-open vault.

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

Repeat `--record` for specific iPhone records or use `--all` for every record in the selected profile. To select records across profiles, repeat `--pick PROFILE_ID:RECORD_ID`. A backup contains every profile and the shortcut setting. Back up the vault’s adjacent `vault.json.export-presets` directory separately to retain presets. Treat backup and export files as readable personal data.

To roll back the app, build the previous release tag in a separate checkout. The vault still uses schema version 1. Older builds may reject newer résumé section assignments in presets, so retain a copy of the preset directory when changing versions.
