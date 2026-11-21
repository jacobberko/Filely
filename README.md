# Filer

Filer is a native macOS app that suggests local files when you open Gmail’s attachment picker in Chrome. It uses the active compose draft to search folders you select and lets you preview a suggestion before attaching it.

## Try it

Requires macOS 26 or later and Xcode with Swift 6. There are no third-party packages or API keys.

```sh
./scripts/build.sh
open build/Filer.app
```

The built-in demo uses fictional files and works without Accessibility access. For live suggestions, add a folder in Filer, then click **Enable** and grant Filer access in **System Settings → Privacy & Security → Accessibility**. Open one Gmail compose draft in Chrome, then click Gmail’s attachment button. Choose a suggestion and click **Attach selected file** to let Filer select it in the native picker.

## How it works

- Filer indexes the folders you select and refreshes the index as files change. Text-based PDFs and common text formats are searchable by content. Other supported files are discoverable by filename and folder.
- Ranking runs locally. The document index and captured draft text stay in memory. Folder bookmarks and preferences are stored on your Mac.
- Live suggestions currently support recognized Gmail compose windows in Chrome with an English-language file picker. Filer attaches a file only after you select it and never sends mail.
- This is a prototype built from source. The build script signs the app locally for development.

## Develop

```sh
./scripts/test.sh
```

`Sources/FilerCore` contains indexing and ranking. `Sources/Filer` contains the app and picker integration. The [integration notes](README_INTEGRATION.md) document behavior and manual checks.

## License

[MIT](LICENSE)
