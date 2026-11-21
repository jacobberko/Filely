import Foundation

/// Value-only decisions shared by live Accessibility integration and offline tests.
enum PickerPolicy {
    enum TransitionObservation: Equatable {
        case samePicker, unavailable, changed, cancelled
    }

    enum TransitionDecision: Equatable {
        case proceed, retry, stopChanged, stopCancelled, timedOut
    }

    /// A temporarily missing AX subtree is not evidence that the picker closed.
    /// Only the original picker becoming available can permit the next action.
    static func transitionDecision(_ observation: TransitionObservation, retryCount: Int, elapsed: TimeInterval,
                                   maximumRetries: Int = 8, timeout: TimeInterval = 3) -> TransitionDecision {
        if observation == .cancelled { return .stopCancelled }
        if observation == .changed { return .stopChanged }
        guard elapsed >= 0, elapsed < timeout, retryCount <= maximumRetries else { return .timedOut }
        if observation == .samePicker { return .proceed }
        return retryCount < maximumRetries ? .retry : .timedOut
    }

    static func canClassifyWindowAsPicker(hasNestedPanel: Bool, hasWebContent: Bool) -> Bool {
        !hasNestedPanel && !hasWebContent
    }

    enum ComposeScopeDecision: Equatable {
        case focused, single, unavailable, ambiguous
    }

    static func composeScope(hasFocusedCompose: Bool, visibleComposeCount: Int) -> ComposeScopeDecision {
        if hasFocusedCompose { return .focused }
        if visibleComposeCount == 1 { return .single }
        return visibleComposeCount > 1 ? .ambiguous : .unavailable
    }

    static func isGmailPageURL(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return url.scheme?.lowercased() == "https" && url.host?.lowercased() == "mail.google.com"
    }

    static func canUseGmailContext(currentPageURL: String, hasMatchingRecentContext: Bool) -> Bool {
        isGmailPageURL(currentPageURL) || (currentPageURL.isEmpty && hasMatchingRecentContext)
    }

    static func canKeepContext(cachedWindowID: UInt, currentWindowID: UInt,
                               cachedPageURL: String, currentPageURL: String,
                               cachedWindowTitle: String, currentWindowTitle: String,
                               age: TimeInterval) -> Bool {
        guard cachedWindowID == currentWindowID, age >= 0, age < 45 else { return false }
        if !currentPageURL.isEmpty && currentPageURL != cachedPageURL { return false }
        if !currentWindowTitle.isEmpty && currentWindowTitle != cachedWindowTitle { return false }
        return true
    }

    static func isOpenPickerCandidate(role: String, buttonTitles: Set<String>, containsFileList: Bool) -> Bool {
        let names = Set(buttonTitles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return ["AXSheet", "AXWindow"].contains(role) && containsFileList && names.contains("cancel") &&
            !names.contains("save") && !names.isDisjoint(with: ["open", "choose", "upload", "select"])
    }

    static func isModernGoToField(fieldIdentifier: String, ancestorIdentifiers: [String], belongsToPicker: Bool) -> Bool {
        belongsToPicker && fieldIdentifier == "PathTextField" && ancestorIdentifiers.contains("GoToWindow")
    }

    static func canDispatchPickerKey(isTargetForeground: Bool, samePickerPresent: Bool, focusBelongsToPicker: Bool) -> Bool {
        isTargetForeground && samePickerPresent && focusBelongsToPicker
    }

    static func composeText(subject: String?, body: String?) -> String? {
        let subject = (subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var pieces = [String]()
        if !subject.isEmpty, subject.lowercased() != "new message" { pieces.append("Subject: \(subject)") }
        if !body.isEmpty, body != subject { pieces.append(body) }
        let text = pieces.joined(separator: "\n")
        return text.isEmpty ? nil : String(text.prefix(14_000))
    }
}
