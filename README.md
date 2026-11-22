# Filely

Filely is an open-source macOS app that predicts which local file you’ll need next from the task at hand. The goal is to make contextual file suggestions work across any website or macOS app, with indexing and ranking on your Mac.

**Current prototype.** Filely uses the active Gmail draft in Chrome to suggest files from folders you choose. You can preview a suggestion before attaching it.

## Try it

Requires macOS 26 or later and Xcode with Swift 6. There are no third-party packages or API keys.

```sh
./scripts/build.sh
open build/Filely.app
```

The built-in demo uses fictional files and works without Accessibility access. For live suggestions, add a folder in Filely, then click **Enable** and grant Filely access in **System Settings → Privacy & Security → Accessibility**. Open one Gmail compose draft in Chrome, then click Gmail’s attachment button. Choose a suggestion and click **Attach selected file** to let Filely select it in the native picker.

## How it works

- Filely indexes the folders you select and refreshes the index as files change. Text-based PDFs and common text formats are searchable by content. Other supported files are discoverable by filename and folder.
- Ranking runs locally. The document index and captured draft text stay in memory. Folder bookmarks and preferences are stored on your Mac.
- Live suggestions currently support recognized Gmail compose windows in Chrome with an English-language file picker. Filely attaches a file only after you select it and never sends mail.
- This is a prototype built from source. The build script signs the app locally for development.

## Machine learning research

A separate research prototype compares the app’s ranking baseline with keyword search, semantic embeddings, and reranking. We measure how often the intended file appears near the top and study cases where the request is ambiguous or the right file is missing. The goal is a reproducible benchmark that other developers can run with synthetic files.

FilelyCore is the reusable Swift library behind the app. Other macOS projects can use it to index local documents and rank them against a query.

## Develop

```sh
./scripts/test.sh
```

`Sources/FilelyCore` contains indexing and ranking. `Sources/Filely` contains the app and picker integration. The [integration notes](README_INTEGRATION.md) document behavior and manual checks.

## License

[MIT](LICENSE)
