import SwiftUI

/// The window's pairing step: the code the iMac shows, and the questions and
/// refusals of the engine's secure connection (PWESecureLink). Shown whenever
/// the engine waits for the person (`PWESecurityState.waitsForUser`).
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
            codeEntry(message: identityChanged ? strings.codeIdentityChanged : strings.codeBody, isError: identityChanged)
        case .wrongCode:
            codeEntry(message: strings.codeWrong, isError: true)
        case .codeExpired:
            codeEntry(message: strings.codeExpired, isError: true)
        case .checkingCode:
            VStack(alignment: .leading, spacing: 14) {
                symbol("lock.shield")
                Text(strings.codeTitle).font(.title3.weight(.semibold))
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(strings.codeChecking).foregroundStyle(.secondary)
                }
                Button(strings.cancel) { model.disconnect() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }
        case .locked:
            notice(symbol: "lock.fill", title: strings.codeTitle, message: strings.codeLocked) {
                Button(strings.tryAgain) { model.retrySecurely() }
                    .buttonStyle(.borderedProminent)
            }
        case .legacyReceiver(let previouslyPaired):
            legacy(previouslyPaired: previouslyPaired)
        case .refused(let reason):
            notice(symbol: "exclamationmark.triangle.fill", title: strings.refusedTitle, message: strings.refused(reason)) {
                if reason != .unencryptedNotAllowed {
                    Button(strings.tryAgain) { model.retrySecurely() }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .none, .negotiating, .encrypted, .unencrypted:
            EmptyView()
        }
    }

    // MARK: - The code

    private func codeEntry(message: String, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            symbol("lock.shield")
            Text(strings.codeTitle).font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            TextField(strings.codePlaceholder, text: $code)
                .font(.system(size: 28, weight: .medium, design: .monospaced))
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
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.count != 6)
                Button(strings.cancel) { model.disconnect() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .onAppear {
            code = ""
            codeFocused = true
        }
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
            notice(symbol: "exclamationmark.triangle.fill", title: strings.refusedTitle,
                   message: strings.legacyPreviouslyPaired) {
                Button(strings.forgetThisIMac) { model.forgetThisIMac() }
            }
        } else {
            let olderPWE = receiver?.runsPWE ?? false
            notice(symbol: "lock.open.fill", title: olderPWE ? strings.legacyOlderPWE : strings.legacyTitle,
                   message: olderPWE ? strings.unencryptedBanner : strings.legacyOriginal) {
                Button(olderPWE ? strings.connectAnywayUnencrypted : strings.connectAnyway) { model.connectUnencrypted() }
            }
        }
    }

    private func notice<Actions: View>(symbol name: String, title: String, message: String,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: name)
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(title).font(.title3.weight(.semibold))
            }
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                actions()
                Button(strings.cancel) { model.disconnect() }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 34, weight: .light))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}
