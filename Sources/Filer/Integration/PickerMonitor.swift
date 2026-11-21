import AppKit
import ApplicationServices
import FilerCore

/// Coordinates use the Accessibility coordinate space: origin at the top left.
struct PickerSession: Equatable {
    let id: String
    let frame: CGRect
    let applicationName: String
    let applicationPID: pid_t
    let context: CapturedContext?

    static func == (lhs: PickerSession, rhs: PickerSession) -> Bool {
        lhs.id == rhs.id && lhs.frame == rhs.frame &&
        lhs.context?.text == rhs.context?.text && lhs.context?.source == rhs.context?.source
    }
}

enum PickerIntegrationError: LocalizedError {
    case accessibilityRequired
    case pickerClosed
    case fileUnavailable
    case navigationUnavailable
    case navigationUnconfirmed
    case selectionUnconfirmed
    case openFailed
    case cancelled
    case targetNotForeground
    case pickerUnavailable

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            return "Allow Filer in Accessibility settings to work with Chrome’s attachment window."
        case .pickerClosed:
            return "The attachment window changed. Open Attach in Chrome and choose the file again."
        case .fileUnavailable:
            return "This file is no longer available. Refresh your folder and try again."
        case .navigationUnavailable:
            return "Chrome’s attachment window didn’t expose its folder field. You can still choose the file in the normal picker."
        case .navigationUnconfirmed:
            return "Filer couldn’t confirm the folder change. Nothing was attached."
        case .selectionUnconfirmed:
            return "Filer couldn’t confirm the selected file. Check it in Chrome’s attachment window and press Open to finish."
        case .openFailed:
            return "Chrome’s attachment window is still open. Check the selection and press Open to finish."
        case .cancelled:
            return "Selection stopped because Filer was paused. Nothing else will be selected."
        case .targetNotForeground:
            return "Bring Chrome’s attachment window to the front, then choose the file again."
        case .pickerUnavailable:
            return "Filer couldn’t verify the attachment window. Reopen Attach in Chrome and try again."
        }
    }
}

/// Polls only the foreground supported application; AX work stays off the UI thread.
/// No context is written to disk or sent to a service.
@MainActor
final class PickerMonitor {
    var onContext: ((CapturedContext?) -> Void)?
    var onPicker: ((PickerSession?) -> Void)?
    var onStatus: ((String) -> Void)?
    var onDiagnostics: ((String) -> Void)?
    private(set) var lastDiagnostics = "Monitor has not started"

    static var isTrusted: Bool { AXIsProcessTrusted() }

    private let worker: PickerWorker
    private let allowedBundleIDs: Set<String>
    private let ownBundleID = Bundle.main.bundleIdentifier
    private var timer: Timer?
    private var pollInFlight = false
    private var selectionInFlight = false
    private var lastSession: PickerSession?
    private var lastContextText: String?
    private var lastStatus = ""
    private var generation = 0
    private var lastChromeDiagnostics = "No Chrome probe yet"

    /// The override is a test seam for a synthetic native Open panel.
    /// Production uses the defaults and requires an identified Gmail page.
    init(allowedBundleIDs: Set<String> = ["com.google.Chrome"], requiresGmailContext: Bool = true) {
        self.allowedBundleIDs = allowedBundleIDs
        self.worker = PickerWorker(requiresGmailContext: requiresGmailContext)
    }

    func start() {
        guard timer == nil else { return }
        generation += 1
        let newTimer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        newTimer.tolerance = 0.15
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
        reportDiagnostics("Monitor started; trusted=\(Self.isTrusted)")
        poll()
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        pollInFlight = false
        worker.reset()
        lastContextText = nil
        lastSession = nil
        onContext?(nil)
        onPicker?(nil)
        reportDiagnostics("Monitor stopped; trusted=\(Self.isTrusted)")
    }

    /// Call only in response to a deliberate user action, such as Enable button.
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if !Self.isTrusted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        poll()
    }

    func select(fileURL: URL, in session: PickerSession, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !selectionInFlight else { return }
        guard Self.isTrusted else {
            reportDiagnostics("Polling; trusted=false")
            completion(.failure(PickerIntegrationError.accessibilityRequired))
            return
        }
        guard lastSession?.id == session.id,
              let app = NSRunningApplication(processIdentifier: session.applicationPID),
              allowedBundleIDs.contains(app.bundleIdentifier ?? "") else {
            completion(.failure(PickerIntegrationError.pickerClosed))
            return
        }
        selectionInFlight = true
        app.activate()
        beginSelectionWhenForeground(fileURL: fileURL, session: session, requestGeneration: generation, attempt: 0, completion: completion)
    }

    private func beginSelectionWhenForeground(fileURL: URL, session: PickerSession, requestGeneration: Int,
                                               attempt: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            guard self.generation == requestGeneration, self.lastSession?.id == session.id else {
                self.selectionInFlight = false
                completion(.failure(PickerIntegrationError.cancelled))
                return
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == session.applicationPID else {
                if attempt < 18 {
                    self.beginSelectionWhenForeground(fileURL: fileURL, session: session, requestGeneration: requestGeneration, attempt: attempt + 1, completion: completion)
                } else {
                    self.selectionInFlight = false
                    completion(.failure(PickerIntegrationError.targetNotForeground))
                }
                return
            }
            self.worker.select(fileURL: fileURL, session: session) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.selectionInFlight = false
                    completion(result)
                    self.poll()
                }
            }
        }
    }

    private func poll() {
        guard timer != nil, !pollInFlight, !selectionInFlight else { return }
        guard Self.isTrusted else {
            publish(PickerSnapshot(status: "Accessibility access is needed", context: nil, picker: nil))
            return
        }

        let front = NSWorkspace.shared.frontmostApplication
        var candidate: NSRunningApplication?
        if let front, allowedBundleIDs.contains(front.bundleIdentifier ?? "") {
            candidate = front
        } else if let front, front.bundleIdentifier == ownBundleID, let session = lastSession {
            // Filer’s settings or preview may briefly take focus. Keep the existing
            // picker visible, but never use this exception to start reading a new app.
            candidate = NSRunningApplication(processIdentifier: session.applicationPID)
        }
        guard let candidate, allowedBundleIDs.contains(candidate.bundleIdentifier ?? "") else {
            worker.reset()
            let frontID = front?.bundleIdentifier ?? "none"
            reportDiagnostics("front=\(frontID); no supported foreground app; last Chrome probe: \(lastChromeDiagnostics)")
            publish(PickerSnapshot(status: "Waiting for Chrome to be active", context: nil, picker: nil))
            return
        }
        pollInFlight = true
        let requestGeneration = generation
        worker.sample(pid: candidate.processIdentifier, name: candidate.localizedName ?? "Chrome") { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self, self.generation == requestGeneration else { return }
                self.pollInFlight = false
                self.lastChromeDiagnostics = snapshot.diagnostics
                self.reportDiagnostics("front=\(front?.bundleIdentifier ?? "none"); \(snapshot.diagnostics)")
                self.publish(snapshot)
            }
        }
    }

    private func publish(_ snapshot: PickerSnapshot) {
        if snapshot.status != lastStatus {
            lastStatus = snapshot.status
            onStatus?(snapshot.status)
        }
        if snapshot.context?.text != lastContextText {
            lastContextText = snapshot.context?.text
            onContext?(snapshot.context)
        }
        if snapshot.picker != lastSession {
            lastSession = snapshot.picker
            onPicker?(snapshot.picker)
        }
    }

    private func reportDiagnostics(_ detail: String) {
        lastDiagnostics = "\(Date().formatted(date: .omitted, time: .standard)) · \(detail)"
        onDiagnostics?(lastDiagnostics)
    }
}

private struct PickerSnapshot {
    let status: String
    let context: CapturedContext?
    let picker: PickerSession?
    var diagnostics: String = ""
}

private struct PageContext {
    let windowID: CFHashCode
    let pageURL: String
    let windowTitle: String
    let context: CapturedContext
}

private final class PickerWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.filer.accessibility", qos: .userInitiated)
    private let requiresGmailContext: Bool
    private var cachedContext: PageContext?
    private var lastCapture = Date.distantPast
    private var enhancedPIDs = Set<pid_t>()
    private var activePID: pid_t?
    private var selecting = false
    private let operationLock = NSLock()
    private var operationRevision = 0
    private var operationEpoch: Int { operationLock.withLock { operationRevision } }
    private var captureDiagnostics = "Capture not attempted"
    private var captureRequiresCacheInvalidation = false

    init(requiresGmailContext: Bool) { self.requiresGmailContext = requiresGmailContext }

    @discardableResult
    private func advanceOperationEpoch() -> Int {
        operationLock.withLock {
            operationRevision += 1
            return operationRevision
        }
    }

    func reset() {
        // Invalidate immediately, even if the worker is inside a slow AX read.
        // Queueing cancellation behind that read could otherwise allow its next
        // keyboard or Open action to run after the user paused Filer.
        advanceOperationEpoch()
        queue.async {
            self.cachedContext = nil
            self.activePID = nil
            self.lastCapture = .distantPast
        }
    }

    func sample(pid: pid_t, name: String, completion: @escaping (PickerSnapshot) -> Void) {
        queue.async {
            guard !self.selecting else { return }
            completion(self.readSnapshot(pid: pid, name: name))
        }
    }

    private func readSnapshot(pid: pid_t, name: String) -> PickerSnapshot {
        if activePID != pid { cachedContext = nil; activePID = pid }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        if !enhancedPIDs.contains(pid) {
            // Chrome exposes its web accessibility tree when an assistive client
            // requests enhanced accessibility. Unsupported apps ignore this.
            _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            enhancedPIDs.insert(pid)
        }
        let windowRead = AX.elementArrayResult(app, "AXWindows")
        let windows = windowRead.elements
        let focused = AX.element(app, "AXFocusedWindow")
        let main = AX.element(app, "AXMainWindow")
        var ordered = [AXUIElement]()
        for item in [focused, main].compactMap({ $0 }) + windows {
            if !ordered.contains(where: { CFEqual($0, item) }) { ordered.append(item) }
        }
        guard !ordered.isEmpty else {
            cachedContext = nil
            return PickerSnapshot(status: "Chrome isn’t exposing any windows", context: nil, picker: nil,
                                  diagnostics: "AXWindows error=\(windowRead.error.rawValue), count=\(windows.count); focusedWindow=\(focused != nil)")
        }
        var picker: AXUIElement?
        var browserWindow: AXUIElement?
        var webArea: AXUIElement?
        for window in ordered.prefix(3) {
            if picker == nil { picker = AX.nativePicker(in: window) }
            if browserWindow == nil, let web = AX.first(in: window, limit: 900, seconds: 0.65, matching: { AX.string($0, "AXRole") == "AXWebArea" }) {
                browserWindow = window
                webArea = web
                break
            }
        }
        if picker == nil, let browserWindow { picker = AX.nativePicker(in: browserWindow) }
        let owner = browserWindow ?? main ?? focused ?? ordered[0]
        let windowID = CFHash(owner)
        let windowTitle = AX.string(owner, "AXTitle")
        let webURL = webArea.map { AX.urlString($0, "AXURL") } ?? ""
        let documentURL = AX.urlString(owner, "AXDocument")
        let pageURL = webURL.isEmpty ? documentURL : webURL
        let diagnostics = "AXWindows error=\(windowRead.error.rawValue), count=\(windows.count); webArea=\(webArea != nil); picker=\(picker != nil); webURL=\(AX.safeOrigin(webURL)); documentURL=\(AX.safeOrigin(documentURL))"
        let isGmail = PickerPolicy.isGmailPageURL(pageURL)
        if let cachedContext,
           !PickerPolicy.canKeepContext(cachedWindowID: cachedContext.windowID, currentWindowID: windowID,
                                        cachedPageURL: cachedContext.pageURL, currentPageURL: pageURL,
                                        cachedWindowTitle: cachedContext.windowTitle, currentWindowTitle: windowTitle,
                                        age: Date().timeIntervalSince(cachedContext.context.capturedAt)) {
            self.cachedContext = nil
        }

        if isGmail, let webArea, (Date().timeIntervalSince(lastCapture) > 1.6 || picker != nil && cachedContext == nil) {
            lastCapture = Date()
            let focus = AX.element(app, "AXFocusedUIElement")
            if let context = captureContext(webArea: webArea, focused: picker == nil ? focus : nil) {
                cachedContext = PageContext(windowID: windowID, pageURL: pageURL, windowTitle: windowTitle, context: context)
            } else if picker == nil || captureRequiresCacheInvalidation {
                cachedContext = nil
            }
        }

        let recentContext = cachedContext.flatMap { cached -> CapturedContext? in
            guard cached.windowID == windowID,
                  Date().timeIntervalSince(cached.context.capturedAt) < 45 else { return nil }
            return cached.context
        }
        let gmailVerified = PickerPolicy.canUseGmailContext(currentPageURL: pageURL, hasMatchingRecentContext: recentContext != nil)
        guard !requiresGmailContext || gmailVerified else {
            cachedContext = nil
            let status = pageURL.isEmpty ? (webArea == nil ? "Chrome’s web content is not available yet" : "Chrome isn’t exposing the page address") : "This Chrome page isn’t a verified Gmail page"
            return PickerSnapshot(status: status, context: nil, picker: nil, diagnostics: diagnostics + "; Gmail=false")
        }
        guard let picker, let frame = AX.frame(picker) else {
            return PickerSnapshot(status: recentContext == nil ? "Open one Gmail draft to get suggestions" : "Gmail context is ready", context: recentContext, picker: nil,
                                  diagnostics: diagnostics + "; Gmail=true; contextCharacters=\(recentContext?.text.count ?? 0); \(captureDiagnostics)")
        }
        let session = PickerSession(id: AX.sessionID(pid: pid, picker: picker), frame: frame,
                                    applicationName: name, applicationPID: pid, context: recentContext)
        return PickerSnapshot(status: recentContext == nil ? "The attachment window is ready; message context is unavailable" : "Finding files for this message",
                              context: recentContext, picker: session,
                              diagnostics: diagnostics + "; Gmail=true; contextCharacters=\(recentContext?.text.count ?? 0); \(captureDiagnostics)")
    }

    private func captureContext(webArea: AXUIElement, focused: AXUIElement?) -> CapturedContext? {
        captureRequiresCacheInvalidation = false
        var focusedCompose: AXUIElement?
        var focusedRoles = [String]()
        if let focused {
            var ancestor: AXUIElement? = focused
            for _ in 0..<16 {
                guard let node = ancestor, !CFEqual(node, webArea) else { break }
                focusedRoles.append("\(AX.string(node, "AXRole"))/\(AX.string(node, "AXSubrole"))")
                if AX.isComposeContainer(node) { focusedCompose = node; break }
                ancestor = AX.element(node, "AXParent")
            }
        }
        var composeContainers = [AXUIElement]()
        if focusedCompose == nil {
            for node in AX.descendants(webArea, limit: 850, seconds: 0.55) where AX.isComposeContainer(node) {
                // Some Chrome versions expose both a dialog and a nested named
                // Compose group for the same draft. Count that as one surface.
                if !composeContainers.contains(where: { AX.hasAncestor(node, equalTo: $0) }) {
                    composeContainers.append(node)
                }
            }
        }
        let scope: AXUIElement
        switch PickerPolicy.composeScope(hasFocusedCompose: focusedCompose != nil, visibleComposeCount: composeContainers.count) {
        case .focused: scope = focusedCompose!
        case .single: scope = composeContainers[0]
        case .unavailable, .ambiguous:
            // A missing or ambiguous compose surface must never fall back to
            // inbox rows or reuse a different draft's cached attachment intent.
            captureRequiresCacheInvalidation = true
            captureDiagnostics = "composeScopes=\(composeContainers.count); no unambiguous draft; focusedRoles=\(focusedRoles.joined(separator: ">"))"
            return nil
        }
        let controls = AX.descendants(scope, limit: 850, seconds: 0.55)
        let subjectField = controls.first {
            AX.string($0, "AXRole") == "AXTextField" && AX.controlLabels($0).contains("subject")
        }
        var subject = subjectField.map { AX.string($0, "AXValue") } ?? ""
        if subject.isEmpty {
            // Older Chrome trees may omit the subject field while retaining the
            // recognized Compose dialog's title. Strip its UI prefix once.
            if let label = [AX.string(scope, "AXTitle"), AX.string(scope, "AXDescription")].first(where: { $0.lowercased().hasPrefix("compose:") }) {
                subject = String(label.dropFirst("Compose:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let bodyControl = controls.first {
            ["AXTextArea", "AXTextField"].contains(AX.string($0, "AXRole")) &&
                AX.controlLabels($0).contains(where: { $0.contains("message body") })
        }
        var body = bodyControl.map { AX.string($0, "AXValue") } ?? ""
        if body.isEmpty, let bodyControl {
            // The fallback is restricted to the identified message editor. It
            // never collects surrounding compose labels, AI helpers, or inbox rows.
            var seen = Set<String>()
            body = AX.descendants(bodyControl, limit: 350, seconds: 0.25).compactMap { node -> String? in
                guard AX.string(node, "AXRole") == "AXStaticText" else { return nil }
                let text = AX.string(node, "AXValue").trimmingCharacters(in: .whitespacesAndNewlines)
                return !text.isEmpty && seen.insert(text).inserted ? text : nil
            }.joined(separator: "\n")
        }
        captureDiagnostics = "draftScope=true; subjectField=\(subjectField != nil); bodyControl=\(bodyControl != nil); focusedRoles=\(focusedRoles.joined(separator: ">"))"
        guard let text = PickerPolicy.composeText(subject: subject, body: body) else {
            captureRequiresCacheInvalidation = true
            return nil
        }
        return CapturedContext(text: text, source: "Gmail · draft", capturedAt: Date())
    }

    func select(fileURL: URL, session: PickerSession, completion: @escaping (Result<Void, Error>) -> Void) {
        let epoch = advanceOperationEpoch()
        queue.async {
            guard self.operationEpoch == epoch else { completion(.failure(PickerIntegrationError.cancelled)); return }
            guard !self.selecting else { return }
            self.selecting = true
            let finish: (Result<Void, Error>) -> Void = { result in
                self.selecting = false
                completion(result)
            }
            let path = fileURL.standardizedFileURL.path
            var directory: ObjCBool = false
            guard fileURL.isFileURL, FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue else {
                finish(.failure(PickerIntegrationError.fileUnavailable)); return
            }
            let app = AXUIElementCreateApplication(session.applicationPID)
            AXUIElementSetMessagingTimeout(app, 0.2)
            guard let picker = AX.matchingPicker(app: app, sessionID: session.id, pid: session.applicationPID) else {
                finish(.failure(PickerIntegrationError.pickerClosed)); return
            }
            if AX.goToField(app: app, picker: picker) == nil {
                guard AX.pressPickerKey(5, flags: [.maskCommand, .maskShift], app: app, session: session, retainedPicker: picker,
                                        isOperationCurrent: { self.operationEpoch == epoch }) else {
                    finish(.failure(PickerIntegrationError.targetNotForeground)); return
                }
            }
            self.awaitGoToField(app: app, picker: picker, session: session, path: path, epoch: epoch,
                                startedAt: ProcessInfo.processInfo.systemUptime, attempt: 0, finish: finish)
        }
    }

    private func selectionObservation(app: AXUIElement, picker: AXUIElement, session: PickerSession,
                                      epoch: Int) -> PickerPolicy.TransitionObservation {
        guard operationEpoch == epoch else { return .cancelled }
        guard AX.foregroundPID() == session.applicationPID else { return .changed }
        guard let current = AX.matchingPicker(app: app, sessionID: session.id, pid: session.applicationPID,
                                             retainedPicker: picker) else { return .unavailable }
        if AX.focusBelongsToPicker(app: app, picker: current) { return .samePicker }
        return AX.hasClearlyDifferentFocusedWindow(app: app, picker: current) ? .changed : .unavailable
    }

    private func awaitGoToField(app: AXUIElement, picker: AXUIElement, session: PickerSession, path: String,
                                epoch: Int, startedAt: TimeInterval, attempt: Int, finish: @escaping (Result<Void, Error>) -> Void) {
        queue.asyncAfter(deadline: .now() + 0.18) {
            var observation = self.selectionObservation(app: app, picker: picker, session: session, epoch: epoch)
            let field = observation == .samePicker ? AX.goToField(app: app, picker: picker) : nil
            if observation == .samePicker && field == nil { observation = .unavailable }
            switch PickerPolicy.transitionDecision(observation, retryCount: attempt,
                                                   elapsed: ProcessInfo.processInfo.systemUptime - startedAt) {
            case .retry:
                self.awaitGoToField(app: app, picker: picker, session: session, path: path, epoch: epoch,
                                    startedAt: startedAt, attempt: attempt + 1, finish: finish)
                return
            case .stopCancelled: finish(.failure(PickerIntegrationError.cancelled)); return
            case .stopChanged: finish(.failure(PickerIntegrationError.pickerClosed)); return
            case .timedOut: finish(.failure(PickerIntegrationError.pickerUnavailable)); return
            case .proceed: break
            }
            guard let field else { finish(.failure(PickerIntegrationError.navigationUnavailable)); return }
            guard self.operationEpoch == epoch else { finish(.failure(PickerIntegrationError.cancelled)); return }
            let result = AXUIElementSetAttributeValue(field, "AXValue" as CFString, path as CFString)
            guard result == .success, AX.string(field, "AXValue") == path else {
                finish(.failure(PickerIntegrationError.navigationUnavailable)); return
            }
            // Return is sent only after reading back our exact path from the
            // verified Go To Folder field, never to Gmail's compose view.
            guard AX.pressPickerKey(36, app: app, session: session, retainedPicker: picker, requiredFocusedElement: field,
                                    isOperationCurrent: { self.operationEpoch == epoch }) else {
                finish(.failure(PickerIntegrationError.navigationUnconfirmed)); return
            }
            self.awaitSelection(app: app, picker: picker, session: session, fileURL: URL(fileURLWithPath: path), epoch: epoch,
                                startedAt: ProcessInfo.processInfo.systemUptime, attempt: 0, finish: finish)
        }
    }

    private func awaitSelection(app: AXUIElement, picker: AXUIElement, session: PickerSession, fileURL: URL,
                                epoch: Int, startedAt: TimeInterval, attempt: Int, finish: @escaping (Result<Void, Error>) -> Void) {
        queue.asyncAfter(deadline: .now() + 0.22) {
            var observation = self.selectionObservation(app: app, picker: picker, session: session, epoch: epoch)
            if observation == .samePicker && (AX.goToField(app: app, picker: picker) != nil || !AX.selectedFileMatches(fileURL, in: picker)) {
                observation = .unavailable
            }
            switch PickerPolicy.transitionDecision(observation, retryCount: attempt,
                                                   elapsed: ProcessInfo.processInfo.systemUptime - startedAt) {
            case .retry:
                self.awaitSelection(app: app, picker: picker, session: session, fileURL: fileURL, epoch: epoch,
                                    startedAt: startedAt, attempt: attempt + 1, finish: finish)
                return
            case .stopCancelled: finish(.failure(PickerIntegrationError.cancelled)); return
            case .stopChanged: finish(.failure(PickerIntegrationError.pickerClosed)); return
            case .timedOut: finish(.failure(PickerIntegrationError.selectionUnconfirmed)); return
            case .proceed: break
            }
            // Recheck the same live picker immediately before Open. A temporarily
            // unavailable or replaced panel never inherits the earlier approval.
            guard self.selectionObservation(app: app, picker: picker, session: session, epoch: epoch) == .samePicker,
                  let button = AX.openButton(in: picker), AX.bool(button, "AXEnabled") != false,
                  self.operationEpoch == epoch,
                  AXUIElementPerformAction(button, "AXPress" as CFString) == .success else {
                finish(.failure(PickerIntegrationError.openFailed)); return
            }
            self.awaitDismissal(app: app, picker: picker, session: session, epoch: epoch,
                                startedAt: ProcessInfo.processInfo.systemUptime, absentSamples: 0, attempt: 0, finish: finish)
        }
    }

    private func awaitDismissal(app: AXUIElement, picker: AXUIElement, session: PickerSession, epoch: Int,
                                startedAt: TimeInterval, absentSamples: Int, attempt: Int,
                                finish: @escaping (Result<Void, Error>) -> Void) {
        queue.asyncAfter(deadline: .now() + 0.2) {
            guard self.operationEpoch == epoch else { finish(.failure(PickerIntegrationError.cancelled)); return }
            let missing = AX.matchingPicker(app: app, sessionID: session.id, pid: session.applicationPID, retainedPicker: picker) == nil
            let consecutiveAbsences = missing ? absentSamples + 1 : 0
            if consecutiveAbsences >= 2 {
                // One missing AX sample can be a transition. Two consecutive
                // absences after the accepted Open action confirm dismissal,
                // not network upload completion or email delivery.
                finish(.success(()))
            } else if PickerPolicy.transitionDecision(.unavailable, retryCount: attempt,
                                                       elapsed: ProcessInfo.processInfo.systemUptime - startedAt) == .retry {
                self.awaitDismissal(app: app, picker: picker, session: session, epoch: epoch,
                                    startedAt: startedAt, absentSamples: consecutiveAbsences, attempt: attempt + 1, finish: finish)
            } else {
                finish(.failure(PickerIntegrationError.openFailed))
            }
        }
    }
}

private enum AX {
    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    static func string(_ element: AXUIElement, _ name: String) -> String {
        value(element, name) as? String ?? ""
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        value(element, name) as? Bool
    }

    static func urlString(_ element: AXUIElement, _ name: String) -> String {
        if let url = value(element, name) as? URL { return url.absoluteString }
        return string(element, name)
    }

    static func controlLabels(_ element: AXUIElement) -> [String] {
        ["AXDescription", "AXTitle", "AXPlaceholderValue"].map {
            string(element, $0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    static func element(_ source: AXUIElement, _ name: String) -> AXUIElement? {
        guard let result = value(source, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    static func elements(_ source: AXUIElement, _ name: String) -> [AXUIElement] {
        value(source, name) as? [AXUIElement] ?? []
    }

    static func elementArrayResult(_ source: AXUIElement, _ name: String) -> (elements: [AXUIElement], error: AXError) {
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(source, name as CFString, &result)
        return (result as? [AXUIElement] ?? [], error)
    }

    static func safeOrigin(_ raw: String) -> String {
        guard !raw.isEmpty else { return "missing" }
        guard let url = URL(string: raw), let scheme = url.scheme, let host = url.host else { return "not an absolute URL" }
        return "\(scheme)://\(host)"
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, "AXPosition"), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, "AXSize"), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions), dimensions.width > 100, dimensions.height > 100 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    static func descendants(_ root: AXUIElement, limit: Int, seconds: TimeInterval, skipWeb: Bool = false) -> [AXUIElement] {
        let deadline = Date().addingTimeInterval(seconds)
        var pending = [root]
        var index = 0
        var visited = [CFHashCode: [AXUIElement]]()
        var result = [AXUIElement]()
        while index < pending.count, result.count < limit, Date() < deadline {
            let node = pending[index]
            index += 1
            let hash = CFHash(node)
            guard !(visited[hash] ?? []).contains(where: { CFEqual($0, node) }) else { continue }
            visited[hash, default: []].append(node)
            if skipWeb && string(node, "AXRole") == "AXWebArea" { continue }
            result.append(node)
            pending.append(contentsOf: elements(node, "AXChildren").prefix(180))
            pending.append(contentsOf: elements(node, "AXSheets").prefix(4))
        }
        return result
    }

    static func first(in root: AXUIElement, limit: Int, seconds: TimeInterval, matching predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(seconds)
        var pending = [root]
        var index = 0
        var visited = [CFHashCode: [AXUIElement]]()
        while index < pending.count, index < limit, Date() < deadline {
            let node = pending[index]
            index += 1
            let hash = CFHash(node)
            guard !(visited[hash] ?? []).contains(where: { CFEqual($0, node) }) else { continue }
            visited[hash, default: []].append(node)
            if predicate(node) { return node }
            let role = string(node, "AXRole")
            if ["AXToolbar", "AXTabGroup", "AXMenuBar", "AXSheet"].contains(role) { continue }
            pending.append(contentsOf: elements(node, "AXChildren").prefix(250))
        }
        return nil
    }

    static func isComposeContainer(_ node: AXUIElement) -> Bool {
        let role = string(node, "AXRole")
        let subrole = string(node, "AXSubrole")
        let isDialog = role == "AXDialog" || subrole == "AXApplicationDialog" || subrole == "AXDialog"
        guard role == "AXGroup" || isDialog else { return false }
        // Gmail can expose its compose surface as a named group rather than
        // a dialog. Generic Gmail dialogs (settings, contacts, etc.) do not qualify.
        if [string(node, "AXTitle"), string(node, "AXDescription")].contains(where: { $0.lowercased().hasPrefix("compose:") }) { return true }
        guard isDialog else { return false }
        let controls = descendants(node, limit: 220, seconds: 0.15)
        let hasBody = controls.contains {
            string($0, "AXRole") == "AXTextArea" &&
                [string($0, "AXDescription"), string($0, "AXTitle")].contains(where: { $0.lowercased().contains("message body") })
        }
        let hasSubject = controls.contains {
            string($0, "AXRole") == "AXTextField" &&
                [string($0, "AXDescription"), string($0, "AXTitle")].contains(where: { $0.lowercased() == "subject" })
        }
        return hasBody && hasSubject
    }

    static func hasAncestor(_ node: AXUIElement, equalTo ancestor: AXUIElement) -> Bool {
        var current: AXUIElement? = node
        for _ in 0..<20 {
            guard let candidate = current else { return false }
            if CFEqual(candidate, ancestor) { return true }
            if string(candidate, "AXRole") == "AXWebArea" { return false }
            current = element(candidate, "AXParent")
        }
        return false
    }

    static func nativePicker(in window: AXUIElement) -> AXUIElement? {
        let candidates = nativeContainerNodes(in: window).filter {
            ["AXSheet", "AXWindow"].contains(string($0, "AXRole"))
        }.sorted { string($0, "AXRole") == "AXSheet" && string($1, "AXRole") != "AXSheet" }
        for candidate in candidates {
            let role = string(candidate, "AXRole")
            guard role == "AXSheet" || role == "AXWindow" else { continue }
            if role == "AXWindow" {
                let nestedPanel = candidates.contains {
                    !CFEqual($0, candidate) && string($0, "AXRole") == "AXSheet" &&
                        string($0, "AXIdentifier") != "GoToWindow" && hasAncestor($0, equalTo: candidate)
                }
                // A browser host window can contain all the Open panel's controls,
                // but must never become the picker merely because its sheet is
                // temporarily unavailable during a modal transition.
                if nestedPanel { continue }
                let hasWebContent = first(in: candidate, limit: 900, seconds: 0.35) { string($0, "AXRole") == "AXWebArea" } != nil
                guard PickerPolicy.canClassifyWindowAsPicker(hasNestedPanel: nestedPanel, hasWebContent: hasWebContent) else { continue }
            }
            let nodes = descendants(candidate, limit: 300, seconds: 0.2, skipWeb: true)
            let buttons = nodes.filter { string($0, "AXRole") == "AXButton" }
            let names = Set(buttons.map { string($0, "AXTitle") })
            let hasFiles = nodes.contains { ["AXBrowser", "AXOutline", "AXTable"].contains(string($0, "AXRole")) }
            guard PickerPolicy.isOpenPickerCandidate(role: role, buttonTitles: names, containsFileList: hasFiles) else { continue }
            return candidate
        }
        return nil
    }

    static func sessionID(pid: pid_t, picker: AXUIElement) -> String { "\(pid)-\(CFHash(picker))" }

    static func matchingPicker(app: AXUIElement, sessionID: String, pid: pid_t, retainedPicker: AXUIElement? = nil) -> AXUIElement? {
        var windows = [AXUIElement]()
        for item in [element(app, "AXFocusedWindow"), element(app, "AXMainWindow")].compactMap({ $0 }) + elements(app, "AXWindows") {
            if !windows.contains(where: { CFEqual($0, item) }) { windows.append(item) }
        }
        if let retainedPicker {
            guard self.sessionID(pid: pid, picker: retainedPicker) == sessionID,
                  ["AXSheet", "AXWindow"].contains(string(retainedPicker, "AXRole")) else { return nil }
            // The original element was already classified as an Open panel.
            // During Go To, validate its identity in the live app hierarchy, not
            // the temporarily hidden Open/Cancel buttons or changing file list.
            if let focused = element(app, "AXFocusedUIElement"), hasAncestor(focused, equalTo: retainedPicker) {
                return retainedPicker
            }
            for window in windows.prefix(5) {
                if let same = nativeContainerNodes(in: window).first(where: { CFEqual($0, retainedPicker) }) { return same }
            }
            return nil
        }
        for window in windows.prefix(5) {
            if let picker = nativePicker(in: window), self.sessionID(pid: pid, picker: picker) == sessionID { return picker }
        }
        return nil
    }

    /// Finds panel topology without walking thousands of file rows or Gmail nodes.
    private static func nativeContainerNodes(in root: AXUIElement) -> [AXUIElement] {
        let deadline = Date().addingTimeInterval(0.35)
        let leafRoles: Set<String> = ["AXWebArea", "AXBrowser", "AXOutline", "AXTable", "AXRow", "AXCell",
                                      "AXStaticText", "AXTextField", "AXTextArea", "AXButton", "AXImage", "AXToolbar", "AXTabGroup"]
        var pending = [root]
        var index = 0
        var result = [AXUIElement]()
        var visited = [CFHashCode: [AXUIElement]]()
        while index < pending.count, result.count < 220, Date() < deadline {
            let node = pending[index]
            index += 1
            let hash = CFHash(node)
            guard !(visited[hash] ?? []).contains(where: { CFEqual($0, node) }) else { continue }
            visited[hash, default: []].append(node)
            let role = string(node, "AXRole")
            if role == "AXWebArea" { continue }
            result.append(node)
            guard !leafRoles.contains(role) else { continue }
            pending.append(contentsOf: elements(node, "AXSheets").prefix(8))
            pending.append(contentsOf: elements(node, "AXChildren").prefix(120))
        }
        return result
    }

    static func focusBelongsToPicker(app: AXUIElement, picker: AXUIElement) -> Bool {
        if let focused = element(app, "AXFocusedUIElement"), hasAncestor(focused, equalTo: picker) { return true }
        guard let window = element(app, "AXFocusedWindow") else { return false }
        return CFEqual(window, picker) || hasAncestor(window, equalTo: picker) || hasAncestor(picker, equalTo: window) ||
            nativeContainerNodes(in: window).contains(where: { CFEqual($0, picker) })
    }

    static func hasClearlyDifferentFocusedWindow(app: AXUIElement, picker: AXUIElement) -> Bool {
        guard let window = element(app, "AXFocusedWindow"), string(window, "AXRole") == "AXWindow",
              string(window, "AXIdentifier") != "GoToWindow", string(window, "AXSubrole") != "AXDialog" else { return false }
        if CFEqual(window, picker) || hasAncestor(window, equalTo: picker) || hasAncestor(picker, equalTo: window) { return false }
        // A different standard Chrome window is a real focus change; unknown
        // modal ancestry remains unavailable and is retried without sending keys.
        return string(window, "AXSubrole") == "AXStandardWindow"
    }

    static func foregroundPID() -> pid_t? {
        DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    }

    static func openButton(in picker: AXUIElement) -> AXUIElement? {
        descendants(picker, limit: 300, seconds: 0.2, skipWeb: true).first {
            string($0, "AXRole") == "AXButton" && ["open", "choose", "upload", "select"].contains(string($0, "AXTitle").lowercased())
        }
    }

    static func goToField(app: AXUIElement, picker: AXUIElement) -> AXUIElement? {
        guard let focused = element(app, "AXFocusedUIElement"),
              ["AXTextField", "AXComboBox"].contains(string(focused, "AXRole")),
              !string(focused, "AXSubrole").lowercased().contains("search"),
              !string(focused, "AXDescription").lowercased().contains("search") else { return nil }
        var ancestors = [focused]
        var ancestor = focused
        for _ in 0..<18 {
            guard let parent = element(ancestor, "AXParent"),
                  !ancestors.contains(where: { CFEqual($0, parent) }) else { break }
            ancestors.append(parent)
            if CFEqual(parent, picker) || string(parent, "AXRole") == "AXApplication" { break }
            ancestor = parent
        }
        let nodes = descendants(picker, limit: 350, seconds: 0.25, skipWeb: true)
        let belongsToPicker = ancestors.contains(where: { CFEqual($0, picker) }) || nodes.contains(where: { CFEqual($0, focused) })
        guard belongsToPicker else { return nil }
        // macOS 27's Go To sheet has these stable native identifiers and may
        // expose only "Go to:" plus a close button, without a Go button.
        if PickerPolicy.isModernGoToField(fieldIdentifier: string(focused, "AXIdentifier"),
                                          ancestorIdentifiers: ancestors.map { string($0, "AXIdentifier") },
                                          belongsToPicker: belongsToPicker) {
            return focused
        }
        let hasGo = nodes.contains {
            let labels = [string($0, "AXTitle"), string($0, "AXValue"), string($0, "AXDescription")].map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            let label = labels.joined(separator: " ")
            return label.contains("go to the folder") || label.contains("go to folder") ||
                labels.contains("go to:") ||
                (string($0, "AXRole") == "AXButton" && string($0, "AXTitle").lowercased() == "go")
        }
        guard hasGo else { return nil }
        return focused
    }

    static func selectedFileMatches(_ file: URL, in picker: AXUIElement) -> Bool {
        let nodes = descendants(picker, limit: 650, seconds: 0.35, skipWeb: true)
        var selected = [AXUIElement]()
        for node in nodes {
            if bool(node, "AXSelected") == true { selected.append(node) }
            selected.append(contentsOf: elements(node, "AXSelectedChildren"))
            selected.append(contentsOf: elements(node, "AXSelectedRows"))
        }
        for node in selected {
            for item in descendants(node, limit: 35, seconds: 0.06, skipWeb: true) {
                if let url = URL(string: urlString(item, "AXURL")), url.isFileURL,
                   url.standardizedFileURL == file.standardizedFileURL { return true }
                if [string(item, "AXValue"), string(item, "AXTitle")].contains(file.lastPathComponent) { return true }
            }
        }
        return false
    }

    static func pressPickerKey(_ key: CGKeyCode, flags: CGEventFlags = [], app: AXUIElement,
                               session: PickerSession, retainedPicker: AXUIElement, requiredFocusedElement: AXUIElement? = nil,
                               isOperationCurrent: () -> Bool) -> Bool {
        guard isOperationCurrent() else { return false }
        guard let picker = matchingPicker(app: app, sessionID: session.id, pid: session.applicationPID,
                                         retainedPicker: retainedPicker) else { return false }
        let focused = element(app, "AXFocusedUIElement")
        if let requiredFocusedElement {
            guard let focused, CFEqual(focused, requiredFocusedElement) else { return false }
        }
        guard PickerPolicy.canDispatchPickerKey(isTargetForeground: foregroundPID() == session.applicationPID,
                                                 samePickerPresent: true, focusBelongsToPicker: focusBelongsToPicker(app: app, picker: picker)) else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        guard isOperationCurrent() else { return false }
        // Native Open panels may be hosted by AppKit's separate panel service.
        // Foreground delivery follows the real focused native control; process-only
        // delivery to Chrome can silently discard both Go To and Return.
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
