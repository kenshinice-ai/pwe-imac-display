import SwiftUI

/// The window's pairing step: the code the iMac shows, and the questions and
/// refusals of the engine's secure connection (PWESecureLink). Shown whenever
/// the engine waits for the person (`PWESecurityState.waitsForUser`). The code
/// field shows only while the iMac waits for a code (PWEPairingRules).
///
/// Every step uses the window's one layout (PWEPhaseLayout): the shield stays in
/// place from the code to the check, and only the words under it change.
struct PWEPairingView: View {
    @ObservedObject var model: PWESenderModel
    let strings: PWEStrings
    let receiver: PWEReceiver?
    let security: PWESecurityState

    @State private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        switch security {
        case .needsCode(_, let identityChanged):
            switch model.codeNote {
            case .wrong?: codeEntry(message: strings.codeWrong, isError: true)
            case .expired?: codeEntry(message: strings.codeExpired, isError: true)
            case nil: codeEntry(message: identityChanged ? strings.codeIdentityChanged : strings.codeBody,
                                isError: identityChanged)
            }
        case .wrongCode:
            requestingCode(after: strings.codeWrongShort)
        case .codeExpired:
            requestingCode(after: strings.codeExpiredShort)
        case .checkingCode:
            PWEPhaseLayout(title: strings.codeTitle) {
                PWESymbol(name: "lock.shield")
            } detail: {
                PWEProgressLine(strings.codeChecking)
            } actions: {
                cancelButton
            }
        case .locked(let seconds):
            locked(seconds: seconds)
        case .legacyReceiver(let previouslyPaired):
            legacy(previouslyPaired: previouslyPaired)
        case .refused(let reason):
            notice(symbol: "exclamationmark.triangle", title: strings.refusedTitle, message: strings.refused(reason)) {
                if reason != .unencryptedNotAllowed {
                    Button(strings.tryAgain) { model.retrySecurely() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        case .none, .negotiating, .encrypted, .unencrypted:
            EmptyView()
        }
    }

    // MARK: - The code

    private func codeEntry(message: String, isError: Bool) -> some View {
        PWEPhaseLayout(title: strings.codeTitle) {
            PWESymbol(name: "lock.shield")
        } detail: {
            if isError { PWENote(message) } else { PWEPhaseText(message) }
        } actions: {
            VStack(alignment: .leading, spacing: 12) {
                // The system font with fixed-width digits, as the iMac shows the code.
                TextField(strings.codePlaceholder, text: $code)
                    .font(.system(size: 28, weight: .medium).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .focused($codeFocused)
                    .onChange(of: code) { _, typed in
                        // Digits only, six at most; spaces as the iMac groups them are fine.
                        let digits = String(typed.filter(\.isNumber).prefix(6))
                        if digits != typed { code = digits }
                    }
                    .onSubmit(submit)
                    .accessibilityLabel(strings.codeTitle)
                HStack(spacing: 10) {
                    Button(strings.pair, action: submit)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(code.count != 6)
                    cancelButton
                }
                .controlSize(.large)
            }
        }
        .onAppear {
            code = ""
            codeFocused = true
        }
    }

    /// A wrong or expired code: the Mac is already asking the iMac for a new one.
    private func requestingCode(after reason: String) -> some View {
        PWEPhaseLayout(title: strings.codeTitle) {
            PWESymbol(name: "lock.shield")
        } detail: {
            PWENote(reason)
            PWEProgressLine(strings.codeRequesting)
        } actions: {
            cancelButton
        }
    }

    /// The iMac locked pairing for a minute: count down; the model asks again at the end.
    private func locked(seconds: Int) -> some View {
        let end = model.lockEnd ?? Date().addingTimeInterval(TimeInterval(seconds))
        return PWEPhaseLayout(title: strings.codeTitle) {
            PWESymbol(name: "lock", tint: .orange)
        } detail: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(strings.codeLocked(seconds: max(PWEPairingRules.secondsLeft(until: end, now: context.date), 1)))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            PWEPhaseText(strings.codeLockedNext)
        } actions: {
            cancelButton
        }
    }

    private var cancelButton: some View {
        Button(strings.cancel) { model.disconnect() }
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
    }

    private func submit() {
        guard code.count == 6 else { return }
        model.submitCode(code)
        code = ""
    }

    // MARK: - Questions

    @ViewBuilder private func legacy(previouslyPaired: Bool) -> some View {
        if previouslyPaired {
            // Paired before, unencrypted now: no one-click downgrade (design §3.4).
            notice(symbol: "exclamationmark.triangle", title: strings.refusedTitle,
                   message: strings.legacyPreviouslyPaired) {
                Button(strings.forgetThisIMac) { model.forgetThisIMac() }
            }
        } else {
            let olderPWE = receiver?.runsPWE ?? false
            notice(symbol: "lock.open", title: olderPWE ? strings.legacyOlderPWE : strings.legacyTitle,
                   message: olderPWE ? strings.unencryptedBanner : strings.legacyOriginal) {
                Button(olderPWE ? strings.connectAnywayUnencrypted : strings.connectAnyway) { model.connectUnencrypted() }
            }
        }
    }

    private func notice<Actions: View>(symbol name: String, title: String, message: String,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        let actions = actions()
        return PWEPhaseLayout(title: title) {
            PWESymbol(name: name, tint: .orange)
        } detail: {
            PWEPhaseText(message)
        } actions: {
            HStack(spacing: 10) {
                actions
                cancelButton
            }
            .controlSize(.large)
        }
    }
}
