# Chrome / Gmail attachment integration

This is a prototype integration using macOS Accessibility. It does not install a Chrome extension, run page JavaScript, read browser databases, modify the clipboard, or send an email. Context remains in memory.

## App interface

- `PickerMonitor()` defaults to Chrome (`com.google.Chrome`) and requires an identified Gmail page.
- `start()` and `stop()` control monitoring. Pausing invalidates pending selection steps and clears cached context.
- `PickerMonitor.isTrusted` reads permission without prompting.
- Instance `requestAccess()` prompts and opens Accessibility settings. Call it only from a user action.
- `onContext` publishes newly captured text or `nil` when context is invalidated. `onPicker` publishes a session or `nil`; the session's optional context is authoritative for ranking.
- A session's rectangle uses Accessibility coordinates, with the origin at the primary display's top left. Convert it before placing an AppKit window.
- A nonactivating suggestion panel preserves Chrome's focus. Temporarily activating Filely keeps an existing picker session; activating another app clears it.
- On a picker update, replace the UI context even when it becomes `nil`, and rerank when context changes as well as when the picker ID changes.

## Current behavior and limits

- Detects native Open/Choose panels with file-list controls and Open/Cancel buttons; ignores Save panels and HTML dialogs. Button-name matching currently expects English.
- Reads draft text only for the HTTPS `mail.google.com` origin. A recognized focused Compose surface is preferred; otherwise exactly one recognized Compose surface is required. Generic dialogs, inbox rows, and the full page are never used as fallback context. Multiple unfocused drafts invalidate cached intent.
- Initial support is explicit Gmail Compose windows. Inline replies and incoming-thread context are not yet supported. A missing compose scope reports `Open one Gmail draft to get suggestions`.
- Context is bounded to 14,000 characters and an 850-node traversal. It is not a structured Gmail integration: layout changes, inaccessible controls, empty drafts, and large drafts may reduce context quality.
- Captured text comes from the Subject field and the labeled Message Body control. When the body has no aggregate value, only static text inside that specific editor is used. Compose headers and neighboring AI-helper fields are excluded.
- Cache identity includes Chrome process, browser window, page URL, and window title. Context expires after 45 seconds. A native picker may hide the URL temporarily; a matching recent cache bridges that case. An observed non-Gmail URL always invalidates it.
- No usable context means an empty suggestion state, not fabricated recommendations. The monitor reports `The attachment window is ready; message context is unavailable` when the picker is recognized but text is unavailable.
- The monitor does not rank files. An empty ranking result is a distinct no-match state handled by the app.
- Selecting requires a user click. Filely revalidates the picker, opens Go To Folder, sets and reads back the exact path, verifies selection, then presses the native Open button. Unsupported Accessibility layouts leave the normal chooser available with an actionable error.
- Keyboard steps wait briefly for Chrome to become foreground and revalidate that focus belongs to the same picker. Events follow the foreground native control so AppKit's remote panel service receives them; they are never sent blindly to Chrome's process or a Gmail editor.
- Go To and file-navigation transitions retain the already validated picker element and re-find that exact identity in the live native hierarchy. A transient missing subtree receives bounded retries (eight retries, a three-second budget per transition), with no path mutation, keyboard input, or Open action until identity and focus are verified again. Pausing or an observed foreground/window change stops the operation.
- Picker lookup ignores web content and file-row subtrees while locating native panels. The enclosing Chrome window cannot substitute for a nested Open sheet. After Open, two consecutive missing samples are required before reporting panel dismissal.
- Go To detection supports macOS 27's native `GoToWindow` / `PathTextField` identifiers as well as older labeled/button layouts. The focused field must belong to the validated picker subtree.
- Selection success means the chooser accepted Open. It does not establish upload completion or email delivery.

## Offline checks

The pure policy tests require no Accessibility permission and read no user data:

```sh
swiftc -module-cache-path /tmp/filely-policy-module-cache Sources/Filely/Integration/PickerPolicy.swift Tests/IntegrationPolicyTests/Runner.swift -o /tmp/filely-integration-policy-tests
/tmp/filely-integration-policy-tests
```

They cover origin spoofing, observed non-Gmail pages, modal URL loss, cross-window/thread changes, cache expiry, Open-versus-Save/dialog classification, and transient-lookup sequences including recovery, cancellation, changed windows, retry exhaustion, and timeouts. They do not establish live Chrome compatibility.

## Live verification checklist

1. Launch the packaged app, use its Enable button, and grant Accessibility access in macOS settings. No permissions database modification is needed or supported.
   During local development, rebuilding an ad-hoc-signed app can leave a stale permission entry. If the toggle is on but the app still reports no access, remove that stale entry and add the exact current app bundle again through System Settings. Do not weaken signing requirements or edit permission databases.
2. Add a folder containing disposable fixture PDFs/documents. Open Gmail in Chrome with one draft and a clear attachment request; do not send it.
3. Click Gmail's attachment button. Confirm the native picker is detected, the suggestions panel sits beside it, and the displayed context belongs to this draft.
4. Choose a fixture file. Confirm Go To Folder resolves the exact path, the native picker closes, and the expected attachment appears in the draft. Remove it afterward.
5. Repeat with spaces and Unicode in filenames, a file in another folder, and a non-default file-list view.
6. Cancel the picker, switch Chrome windows/tabs, switch apps, pause Filely, and revoke Accessibility access. Confirm suggestions disappear and no later selection step executes.
7. Try Save As, a non-Gmail upload field, the Gmail inbox with no Compose window, an empty draft, two open compose windows, a missing file, and a request with no matching fixture. Confirm no inbox text, stale recommendation, or unintended Open action is used. With two drafts, opening the picker must invalidate previously focused draft intent unless the active compose surface is unambiguous.
8. Inspect light/dark appearance and window placement on a second display. Automatic reading and selection must be verified separately from a styled demo.
9. Start in a folder with many files, choose a suggestion, and repeat the Go To transition. Confirm a temporary Accessibility refresh does not require a second Attach click. While Go To is opening, cancel the native picker or switch Chrome windows; confirm no path or keystroke is sent to a replacement picker or the message editor.

For a disposable native-panel harness, `PickerMonitor(allowedBundleIDs: [harnessBundleID], requiresGmailContext: false)` permits detection/selection without pretending the harness supplies Gmail context. Never use that override in the shipped app.
