# VeraData vault specification, version 1

A vault can be inspected and edited with an ordinary UTF-8 text editor. The [fictional vault](../Sources/VeraDataApp/Resources/demo.json) is a complete example. Structural validators can use the [Draft 2020-12 schema](../schema/vault-v1.schema.json). The application additionally validates ID uniqueness, dates, referential integrity for aliases, and input limits.

## Exchange format

The root object contains the literal integer `version` with value `1`, `settings`, and a nonempty `profiles` array. Each profile has an `id`, `name`, and a `records` array. Each record has an `id`, `kind`, `label`, and `fields` object. It can also have an `aliases` object. Unknown keys at the envelope, profile, settings, or record level are rejected. Add custom information to `fields`.

Profile IDs are unique within a vault. Record IDs are unique within a profile. IDs are case-sensitive and stay with their record across edits. Use 1–128 ASCII letters, digits, underscores, or hyphens, starting with a letter or digit. Names and labels are display text and can be repeated. Array order is saved and establishes the order within a category. Existing ID spelling and field-key spelling are kept.

The parser accepts [RFC 8259 JSON](https://datatracker.ietf.org/doc/html/rfc8259) encoded in UTF-8. It rejects duplicate keys, trailing commas, JSON5 constructs, unpaired surrogate escapes, and unsupported versions. It limits input and output to 16 MiB and JSON nesting to 64 levels beneath the root. The application writes UTF-8, LF newlines, two-space indentation, sorted object keys, and a trailing newline. The exact layout of imported JSON can change on export. Unicode-equivalent field names collide in the app’s string model.

| Stored form | Meaning |
| --- | --- |
| Field omitted | No value has been supplied |
| `null` | The value is explicitly unknown |
| `""` | The value is explicitly empty text |
| `"000184"` | Text with all six characters preserved |
| `900719925474099312345` | Number whose original digits are retained by VeraData |

Custom values can contain strings, numbers, booleans, nulls, arrays, or objects. VeraData preserves numeric digits and exponent spelling. Consumers that parse numbers as binary floating point may lose precision. For identifiers and values where textual fidelity matters in other apps, use strings. Text such as `{{field}}` and HTML is data. VeraData displays and copies it literally.

## Built-in records

Known fields accept text or null, except the listed arrays and date constraints. Any known field can be omitted.

| Kind | Built-in fields |
| --- | --- |
| `contact` | `name`, `givenName`, `familyName`, `email`, `phone` |
| `address` | `use`, `line1`, `line2`, `city`, `region`, `postalCode`, `country`, `formatted`, `startDate`, `endDate` |
| `employment` | `employer`, `legalName`, `title`, `startDate`, `endDate`, `location`, `employerAddress`, `employmentType`, `responsibilities`, `achievements`, `supervisor`, `reasonForLeaving`, `verificationContact` |
| `education` | `institution`, `qualification`, `fieldOfStudy`, `startDate`, `endDate`, `location` |
| `custom` | User-defined fields |

- Addresses use `Residential`, `Mailing`, `Billing`, `Shipping`, or `Other` when the nonempty `use` field is supplied. A dated `endDate` identifies a historical address in the interface. An omitted or empty end date is displayed as open-ended. A null end date is displayed as unknown. These labels describe the stored record.
- `responsibilities` and `achievements` are arrays of strings or null. The editor displays one item per line.
- A nonempty date string is `YYYY`, `YYYY-MM`, or `YYYY-MM-DD`. Dates follow the proleptic Gregorian calendar and have no time zone. Year and month values remain available only at the precision supplied.
- A phone number is stored as text, including the original punctuation or extension. A number entered with a leading plus sign and supported punctuation can also be copied with the punctuation removed. VeraData does not infer a country code.
- An address normally offers a computed summary of its stored components. Use `formatted` to supply complete mailing lines if the computed line order is unsuitable.
- Address records can store decimal degrees in optional custom fields named `latitude` and `longitude`. VeraData uses a complete pair in the ranges −90 to 90 and −180 to 180. Each coordinate may be text or a JSON decimal number written without an exponent. The computed pair uses latitude first and preserves fractional digits. Other values can remain in these custom fields.
- Distinct jobs with the same employer label have their own record IDs and historical fields. The current format has no organization foreign keys.

`aliases` maps a shortcut such as `";ph"` to a stored top-level field key such as `"phone"`. A shortcut contains a leading semicolon followed by one or more non-whitespace, non-semicolon characters. Lookup is case-insensitive within the active profile and optional record scope. Multiple matches remain individually selectable. The app also searches built-in synonyms, labels, and values.

`settings.searchShortcut` is one of `space`, `j`, `k`, or `off`. These represent Control–Option with the named key, or no global shortcut. The currently viewed profile and temporary search scope stay outside the backup.

## Selective projection

**File › Export Data** selects fields across records from the active profile. The preview is the exact JSON written to disk. Every format starts with an empty selection.

| Format | Shape and behavior |
| --- | --- |
| Structured JSON | An object with `format: "veradata-selection"`, `version: 1`, and an ordered `records` array. Each entry has a `kind` and its selected `fields`. Record/profile names, internal IDs, aliases, and settings are excluded. Whole values keep their original types. Selected list items keep their original relative order. |
| Résumé data (JSON) | A flat object compatible with VeraFlow. Selected contact, work, and education fields map to `name`, `email`, `phone`, `summary`, `experience_markdown`, and `education_markdown`. Optional contact field IDs `headline`, `website`, `portfolio`, `linkedin`, and `github` add a headline and links. Selected custom records assigned to Skills, Languages, or Certifications contribute to `skills_markdown`. Selected Projects contributes to `projects_markdown`. |

The résumé mapping formats selected details and bullets as Markdown, escapes Markdown punctuation in stored text, and flattens line breaks inside a single value to spaces. Unknown or omitted dates produce no date text, and year or month precision is preserved. Line items stay in source order within their original field. Structured JSON preserves original text, including line breaks. Résumé records keep the selected order. A selected `title` in a project record becomes its heading. Contact and recognized project links display the full address for print. A certification can combine its name, issuer, and year on one line. Other selected custom text and list items become bullets. Record display names stay private. Use the [canonical VeraFlow résumé form](https://github.com/iandorsey00/veraflow/blob/main/examples/source/resume-pdf.vf) to arrange these values.

**Export Selected Fields** copies only the checked top-level scalar fields of a record to a flat JSON object, with their original names and types. Optional fields can be omitted and explicit null is retained. Arrays, objects, aliases, profiles, and application settings are outside this projection. Flat exports can be used with VeraFlow when the selected field names and values satisfy its source-record rules.

For example, choose **First name** and **Reference code** from the demo contact. The exported content is:

```json
{
  "Reference code": "000184",
  "givenName": "Morgan"
}
```

The demonstration can also be read by `python3 scripts/check-portability.py`. Supply the path to a backup containing the demo profile to exercise the same workflow on an actual export.

## Compatibility

Version 1 is the initial format. The app rejects older and newer version numbers. A future incompatible change needs a new version and a tested migration that leaves the original available for recovery. JSON5, JSON Resume adaptation, cross-record relationships, attachments, and evidence locators are possible future extensions.

## Additive record import

**File › Import Records** accepts the same JSON file limits as vault import. Supported inputs are:

- VeraData backups and iPhone transfers. Choose a source profile and a destination. Other user profiles and vault settings are outside the import.
- The structured selection export. Where the file omits a label, VeraData uses selected fields or the record kind to make a review label.
- A [record import file](../examples/record-import.json) with `format: "veradata-import"`, integer `version: 1`, and a `records` array. Each record has a supported `kind` and nonempty `fields` object, plus optional `id`, `label`, and `aliases`. Values retain their JSON types and nested structure. PDFs, spreadsheets, and OCR or AI results can be converted into this JSON by an independent tool.
- A nonempty plain JSON object. Its keys become fields on a single custom record.

Suggested matches are limited to the chosen destination and the same record kind. Matches start as skipped. Updates preserve the existing record ID, label, aliases, and every field you leave unchecked. Selecting an explicit null sets a field to unknown. An omitted key is never removed. If you add a record with a conflicting ID, the new record receives a fresh ID.

An employment `endDate` can also be the string `"Present"`. Creating or importing it normalizes `present` and `至今` to that spelling. Omitting the date still means no date was supplied. Earlier versions may reject a vault with the new value, so upgrade the receiving app before transferring such records to it.

## iPhone transfers

In VeraData for Mac, choose **File › Export for iPhone**. Check individual records or select all records in a profile. The export includes each checked record in full, including its custom fields and aliases. Unchecked records, empty profiles, and desktop settings are omitted.

A transfer is UTF-8 JSON with the following envelope:

```json
{
  "format": "veradata-mobile",
  "version": 1,
  "profiles": [
    {
      "id": "demo",
      "name": "Fictional demo",
      "records": [
        {"id": "contact-1", "kind": "contact", "label": "Fictional contact", "fields": {"phone": "+1 202 555 0142"}}
      ]
    }
  ]
}
```

In a valid file, `profiles` contains at least one profile, and every profile contains at least one record. Profiles and records use the same structure and validation rules as backups. The format identifier prevents a full Mac backup from being accepted as a phone transfer.

On iPhone, choose **Import Transfer** and pick the file in Files. Import validates the complete file before replacing a previous download. VeraData keeps a protected local copy for offline lookup. You can remove that copy from the app’s options menu. The original transfer file remains wherever you saved it.

The transfer file is readable JSON. Use the existing **Export Selected Fields** action on Mac for a smaller file when a recipient only needs specific fields from a record.

## Change sets and live preset selections

A [version 1 change set](../schema/change-set-v1.schema.json) names an existing profile ID and an ordered list of record or preset edits. The CLI validates it against the current vault, previews the diff, and requires the preview token to apply it. The same state change either completes as a unit or remains pending for journal recovery. See the [CLI guide](cli.md#review-and-apply-a-batch) for the operations and a fictional example.

A whole-field preset selection follows the live value, including changed object contents and added or removed list items. Indexed list selections keep their fingerprints and require review when the source list changes. Older preset definitions load with these rules. Newly saved presets use version 2. The vault and transfer schemas, and ordinary export values, remain separate from transaction and revision metadata.
