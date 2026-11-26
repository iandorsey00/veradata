# VeraData

VeraData is a local-first macOS utility for keeping reusable information close at hand. Save a phone number, address, or employment record once, then find and copy the detail a form asks for. A job can stay selected while you look up its start date, title, and responsibilities.

## Try it

Build on macOS 14 or later with Swift 6 and the macOS SDK. The build has no third-party dependencies.

```sh
./scripts/build-app.sh
open dist/VeraData.app
```

This creates an ad-hoc-signed app for local use. Leave VeraData running to use its global shortcut.

1. Click **Open Fictional Demo**. In another app, press **⌃⌥Space**, type `phone`, press **Return**, and paste with **⌘V**. The expected value is `+1 (202) 555-0142`.
2. Open Quick Search again. Search for `Juniper` and press **Return** on one of the company’s two roles. The role and dates appear at the top of the palette.
3. Search for `start year` and press **Return**. Operations Lead gives `2024` and Operations Coordinator gives `2022`. Use the arrows in the palette to switch roles or **Search All** to clear the scope.
4. Use the profile menu to switch back to **Personal** and add your own records.

You can also invoke search with **⌘K** inside VeraData. If the global shortcut conflicts with another app, choose an alternative in **Records › Global Search Shortcut**.

## Everyday use

- **Store details.** Contact, address, employment, and education editors provide suggested fields. Add a custom field for anything else. The field state distinguishes omitted, unknown, and present values. If you enter a month or year only, VeraData preserves that precision.
- **Find a field.** Search by employer, job title, field name, or familiar names such as `phone` and `job duties`. Under **Search Shortcuts** in the editor, you can add exact aliases such as `;ph`.
- **Work through several jobs.** **Search This Record** pins a job in Quick Search. The palette remembers its scope until you switch records or choose **Search All**. In the main window, use **⌘[** and **⌘]** to step through records of the same type.
- **Choose a format.** The **Format** menu offers available date components, phone digits, and responsibility bullets. The phone options remove punctuation without inferring a dialing country. For addresses that require a country-specific layout, enter the intended postal lines in **Mailing lines**.
- **Copy today or now.** In Quick Search, type `today` for the date on your Mac or `timestamp` for the current local time with a UTC offset. The **Format** menu also offers a localized date, UTC time, and Unix seconds where applicable.
- **Find saved coordinates.** In an address editor, choose **Add Coordinates** and enter decimal latitude and longitude. Search for the address name and `coordinates` to copy the pair for a map or form.
- **Keep address history.** Add a new address record when you move. Enter the previous address’s **Through** date so it appears as historical. Address use and date history are stored independently.
- **Share selected data.** Choose **File › Export Data** to select fields and individual list items across the active profile. Arrange the records, then review the exact JSON before saving. Use a record’s **Export Selected Fields** command for the original single-record flat JSON format.
- **Back up everything.** Choose **File › Back Up Vault** for all profiles, values, aliases, and the global shortcut. **File › Restore Vault** validates a backup and asks before replacing the current vault. The vault and exports contain readable JSON.

## Build a résumé in VeraFlow

1. In VeraData, choose **File › Export Data** and set **Format** to **VeraFlow résumé**.
2. Select the contact details, work history, and education you want. Expand a responsibilities or accomplishments field to select individual bullets. Use the arrows to order jobs or education entries.
3. Choose **Review**, check the exact file, and save it.
4. In VeraFlow Desktop, choose **Open JSON / JSON5**, open the export, and choose **Use a form file** with [VeraData-Resume.vf](examples/VeraData-Resume.vf). Copy the rendered Markdown to your preferred editor for final layout.

For other workflows, choose **Structured JSON**. It preserves selected lists, objects, and scalar types without requiring VeraFlow. [Export formats](docs/specification.md#selective-projection)

## VeraData on iPhone

The read-only companion lives in this repository and shares the Mac app’s validation, search, and field formatting. It requires iOS 17 or later. To build locally, open [iOS/VeraData.xcodeproj](iOS/VeraData.xcodeproj) in the full Xcode app and select the **VeraDataPhone** scheme. Choose a simulator, or choose a signing team and your iPhone for a device build.

1. On Mac, choose **File › Export for iPhone** and check the records you want on your phone. All fields in each checked record are included.
2. Transfer the JSON file to your iPhone and select it under **Import Transfer**. Future imports replace the downloaded snapshot after confirmation.
3. Switch profiles, search in either language, then tap Copy by the value you want. Use the format menu when a field has multiple representations.

The interface follows the app’s system language in English or Simplified Chinese. Record contents stay in the language you entered. Imported records are available offline.

### iPhone 使用方式

在 Mac 上选择 **文件 › 导出到 iPhone**，勾选要携带的记录。将 JSON 文件传到 iPhone 后，在 VeraData 中选择 **导入传输文件**。导入后可离线搜索并复制字段。界面支持英语和简体中文，已保存的内容保留原文。

## Development

```sh
./scripts/test.sh
```

See the [data specification](docs/specification.md), [JSON Schema](schema/vault-v1.schema.json), [fictional example](Sources/VeraDataApp/Resources/demo.json), and [architecture, privacy, and recovery guide](docs/architecture.md).

Browser autofill and document evidence are future work. Licensed under [MIT](LICENSE).
