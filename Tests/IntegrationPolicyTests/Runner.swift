import Foundation

@main
struct IntegrationPolicyTests {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
            checks += 1
            if !condition() { fatalError("Failed: \(description)") }
        }

        expect(PickerPolicy.isGmailPageURL("https://mail.google.com/mail/u/0/#inbox/thread123"), "real Gmail conversation accepted")
        expect(!PickerPolicy.isGmailPageURL("https://mail.google.com.attacker.example/"), "lookalike host rejected")
        expect(!PickerPolicy.isGmailPageURL("https://mail.google.com@attacker.example/"), "URL credentials cannot spoof Gmail host")
        expect(!PickerPolicy.isGmailPageURL("https://example.com/mail.google.com"), "Gmail in path rejected")
        expect(!PickerPolicy.isGmailPageURL("http://mail.google.com/"), "unencrypted Gmail origin rejected")
        expect(!PickerPolicy.isGmailPageURL(""), "missing URL is not itself evidence of Gmail")

        let url = "https://mail.google.com/mail/u/0/#inbox/thread123"
        func keep(window: UInt = 1, currentURL: String = url, title: String = "Proposal - Gmail", age: TimeInterval = 5) -> Bool {
            PickerPolicy.canKeepContext(cachedWindowID: 1, currentWindowID: window, cachedPageURL: url,
                                        currentPageURL: currentURL, cachedWindowTitle: "Proposal - Gmail",
                                        currentWindowTitle: title, age: age)
        }
        expect(keep(), "same page retains fresh context")
        expect(keep(currentURL: ""), "modal picker may temporarily hide the page URL")
        expect(!keep(window: 2), "different Chrome window cannot inherit context")
        expect(!keep(currentURL: "https://mail.google.com/mail/u/0/#inbox/other"), "another Gmail thread invalidates context")
        expect(!keep(title: "Budget - Gmail"), "title change invalidates context even if Gmail route is unchanged")
        expect(!keep(age: 45), "45-second context expires")
        expect(!keep(age: -1), "future timestamp is rejected")
        expect(PickerPolicy.canUseGmailContext(currentPageURL: "", hasMatchingRecentContext: true), "verified cache bridges modal URL loss")
        expect(!PickerPolicy.canUseGmailContext(currentPageURL: "", hasMatchingRecentContext: false), "missing URL without cache is rejected")
        expect(!PickerPolicy.canUseGmailContext(currentPageURL: "https://example.com/", hasMatchingRecentContext: true), "cache never overrides observed non-Gmail page")

        expect(PickerPolicy.isOpenPickerCandidate(role: "AXSheet", buttonTitles: ["Open", "Cancel"], containsFileList: true), "normal Open sheet accepted")
        expect(PickerPolicy.isOpenPickerCandidate(role: "AXWindow", buttonTitles: ["Choose", "Cancel"], containsFileList: true), "standalone native chooser accepted")
        expect(!PickerPolicy.isOpenPickerCandidate(role: "AXSheet", buttonTitles: ["Save", "Cancel"], containsFileList: true), "Save dialog rejected")
        expect(!PickerPolicy.isOpenPickerCandidate(role: "AXSheet", buttonTitles: ["Open", "Save", "Cancel"], containsFileList: true), "ambiguous Save dialog rejected")
        expect(!PickerPolicy.isOpenPickerCandidate(role: "AXSheet", buttonTitles: ["Open", "Cancel"], containsFileList: false), "generic confirmation dialog rejected")
        expect(!PickerPolicy.isOpenPickerCandidate(role: "AXDialog", buttonTitles: ["Open", "Cancel"], containsFileList: true), "HTML dialog rejected")
        expect(!PickerPolicy.isOpenPickerCandidate(role: "AXSheet", buttonTitles: ["Open"], containsFileList: true), "incomplete chooser evidence rejected")
        expect(PickerPolicy.isModernGoToField(fieldIdentifier: "PathTextField", ancestorIdentifiers: ["GoToWindow"], belongsToPicker: true), "macOS 27 Go To path field accepted without a Go button")
        expect(!PickerPolicy.isModernGoToField(fieldIdentifier: "PathTextField", ancestorIdentifiers: ["GoToWindow"], belongsToPicker: false), "another panel's Go To field rejected")
        expect(!PickerPolicy.isModernGoToField(fieldIdentifier: "SearchField", ancestorIdentifiers: ["GoToWindow"], belongsToPicker: true), "search field cannot receive a file path")
        expect(!PickerPolicy.isModernGoToField(fieldIdentifier: "PathTextField", ancestorIdentifiers: ["OtherWindow"], belongsToPicker: true), "path-like field outside native Go To rejected")
        expect(PickerPolicy.composeScope(hasFocusedCompose: false, visibleComposeCount: 0) == .unavailable, "inbox without compose cannot become attachment context")
        expect(PickerPolicy.composeScope(hasFocusedCompose: false, visibleComposeCount: 1) == .single, "one unambiguous compose surface is usable while picker has focus")
        expect(PickerPolicy.composeScope(hasFocusedCompose: false, visibleComposeCount: 2) == .ambiguous, "multiple unfocused drafts invalidate cached intent")
        expect(PickerPolicy.composeScope(hasFocusedCompose: true, visibleComposeCount: 2) == .focused, "an explicitly focused compose surface disambiguates drafts")
        expect(PickerPolicy.canDispatchPickerKey(isTargetForeground: true, samePickerPresent: true, focusBelongsToPicker: true), "keyboard dispatch requires the active validated picker")
        expect(!PickerPolicy.canDispatchPickerKey(isTargetForeground: false, samePickerPresent: true, focusBelongsToPicker: true), "keys cannot go to another foreground app")
        expect(!PickerPolicy.canDispatchPickerKey(isTargetForeground: true, samePickerPresent: false, focusBelongsToPicker: true), "closed picker blocks keyboard dispatch")
        expect(!PickerPolicy.canDispatchPickerKey(isTargetForeground: true, samePickerPresent: true, focusBelongsToPicker: false), "another Chrome window or Gmail editor cannot receive picker keys")
        expect(PickerPolicy.composeText(subject: " Resume ", body: "Please attach my current resume.") == "Subject: Resume\nPlease attach my current resume.", "structured subject and body form clean context")
        expect(PickerPolicy.composeText(subject: "New Message", body: "   ") == nil, "empty compose placeholder is not context")
        expect(PickerPolicy.composeText(subject: "Resume", body: "Resume") == "Subject: Resume", "identical subject and body are not duplicated")
        expect(PickerPolicy.composeText(subject: nil, body: String(repeating: "x", count: 15_000))?.count == 14_000, "structured context remains bounded")

        expect(PickerPolicy.transitionDecision(.unavailable, retryCount: 0, elapsed: 0.18) == .retry, "first modal AX lookup miss waits instead of declaring the picker closed")
        let transientSequence: [PickerPolicy.TransitionObservation] = [.unavailable, .unavailable, .samePicker]
        let transientDecisions = transientSequence.enumerated().map {
            PickerPolicy.transitionDecision($0.element, retryCount: $0.offset, elapsed: Double($0.offset + 1) * 0.18)
        }
        expect(transientDecisions == [.retry, .retry, .proceed], "Go To becomes actionable only after the original picker returns")
        let cancelledSequence: [PickerPolicy.TransitionObservation] = [.unavailable, .cancelled]
        let cancelledDecisions = cancelledSequence.enumerated().map {
            PickerPolicy.transitionDecision($0.element, retryCount: $0.offset, elapsed: Double($0.offset + 1) * 0.18)
        }
        expect(cancelledDecisions == [.retry, .stopCancelled], "pausing while Go To is unavailable cancels instead of continuing")
        expect(PickerPolicy.transitionDecision(.changed, retryCount: 1, elapsed: 0.36) == .stopChanged, "a different Chrome window or picker cannot inherit the selection")
        expect(PickerPolicy.transitionDecision(.unavailable, retryCount: 8, elapsed: 1.6) == .timedOut, "persistent missing picker reaches retry-count limit")
        expect(PickerPolicy.transitionDecision(.unavailable, retryCount: 2, elapsed: 3) == .timedOut, "slow AX calls cannot extend the transition time budget")
        expect(PickerPolicy.transitionDecision(.samePicker, retryCount: 3, elapsed: 3.1) == .timedOut, "a late picker result cannot restart an expired action")
        expect(PickerPolicy.transitionDecision(.cancelled, retryCount: 9, elapsed: 4) == .stopCancelled, "explicit cancellation wins over timeout")
        expect(PickerPolicy.transitionDecision(.changed, retryCount: 9, elapsed: 4) == .stopChanged, "observed window change wins over timeout")
        expect(PickerPolicy.transitionDecision(.samePicker, retryCount: 8, elapsed: 2) == .proceed, "original picker may succeed on the final allowed retry")
        expect(PickerPolicy.transitionDecision(.samePicker, retryCount: 9, elapsed: 2) == .timedOut, "exhausted retry budget cannot dispatch a key")
        expect(PickerPolicy.transitionDecision(.unavailable, retryCount: 0, elapsed: -1) == .timedOut, "invalid clock interval fails closed")
        expect(!PickerPolicy.canClassifyWindowAsPicker(hasNestedPanel: true, hasWebContent: false), "host window cannot replace its nested native picker")
        expect(!PickerPolicy.canClassifyWindowAsPicker(hasNestedPanel: false, hasWebContent: true), "Chrome web window cannot become the picker after a sheet lookup miss")
        expect(PickerPolicy.canClassifyWindowAsPicker(hasNestedPanel: false, hasWebContent: false), "standalone native Open windows remain eligible")
        print("Passed \(checks) integration policy checks.")
    }
}
