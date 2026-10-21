import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

/// Optional account security belongs to the Bound account, independently of device sync.
struct BoundAccountSecurityView: View {
    @ObservedObject var account: BoundFriendAccount
    @State private var enrollmentCode = ""
    @State private var verificationCode = ""
    @State private var selectedFactorID: String?
    @State private var submission: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var factorToRemove: String?
    @State private var passkeyToRemove: String?

    private var authenticatorFactors: [BoundSecurityFactor] {
        account.securityFactors.filter { $0.factorType == "totp" }
    }
    private var hasAuthenticator: Bool {
        !verifiedAuthenticators.isEmpty
    }
    private var verifiedAuthenticators: [BoundSecurityFactor] {
        authenticatorFactors.filter { $0.status == "verified" }
    }
    private var unavailable: Bool {
        account.securityBusy || account.busy || account.deletionPending || submission != nil
    }
    private var needsVerification: Bool { hasAuthenticator && !account.securityAAL2 }

    var body: some View {
        Form {
            if account.session == nil {
                Section { Text("Sign in to manage your account security.") }
            } else {
                Section("Password") {
                    BoundAccountPasswordResetLink(account: account)
                }
                authenticatorSection
                if let enrollment = account.totpEnrollment {
                    enrollmentSection(enrollment)
                }
                if needsVerification { verificationSection }
                passkeysSection
                if account.securityBusy { Section { ProgressView("Updating account security…") } }
                if !account.securityStatus.isEmpty {
                    Section {
                        Text(account.securityStatus)
                            .accessibilityIdentifier("account.security.status")
                    }
                }
            }
        }
        .navigationTitle("Account security")
        .task(id: account.securityIdentityID) {
            operationID = UUID(); submission?.cancel(); submission = nil
            clearInputs()
            await account.loadAccountSecurity()
        }
        .onChange(of: verifiedAuthenticators.map(\.id)) { ids in
            verificationCode = ""
            if let id = selectedFactorID, !ids.contains(id) { selectedFactorID = nil }
        }
        .onDisappear {
            operationID = UUID()
            submission?.cancel(); submission = nil
            clearInputs()
            account.discardTOTPEnrollment()
        }
        .confirmationDialog("Remove authenticator?", isPresented: Binding(
            get: { factorToRemove != nil }, set: { if !$0 { factorToRemove = nil } }
        ), titleVisibility: .visible) {
            Button("Remove authenticator", role: .destructive) {
                guard let factorID = factorToRemove else { return }
                factorToRemove = nil
                perform { _ = await account.unenrollTOTP(factorID: factorID) }
            }
            Button("Cancel", role: .cancel) { factorToRemove = nil }
        } message: {
            Text("This authenticator will no longer protect your Bound account. Keep another sign-in method available.")
        }
        .confirmationDialog("Remove passkey?", isPresented: Binding(
            get: { passkeyToRemove != nil }, set: { if !$0 { passkeyToRemove = nil } }
        ), titleVisibility: .visible) {
            Button("Remove passkey", role: .destructive) {
                guard let passkeyID = passkeyToRemove else { return }
                passkeyToRemove = nil
                perform { _ = await account.deletePasskey(id: passkeyID) }
            }
            Button("Cancel", role: .cancel) { passkeyToRemove = nil }
        } message: {
            Text("This passkey will no longer sign in to your Bound account. Your password stays available.")
        }
    }

    private var authenticatorSection: some View {
        Section {
            if authenticatorFactors.isEmpty {
                Text("No authenticator enabled").foregroundStyle(.secondary)
                    .accessibilityIdentifier("account.security.totp.disabled")
            }
            ForEach(authenticatorFactors) { factor in
                HStack {
                    VStack(alignment: .leading) {
                        Text(factor.friendlyName.isEmpty ? "Authenticator" : factor.friendlyName)
                        Text(factor.status == "verified" ? "Enabled" : "Setup incomplete")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { factorToRemove = factor.id }
                        .disabled(unavailable || (factor.status == "verified" && !account.securityAAL2))
                        .accessibilityLabel("Remove \(factor.friendlyName.isEmpty ? "authenticator" : factor.friendlyName)")
                        .accessibilityIdentifier("account.security.totp.remove.\(factor.id)")
                }
            }
            if account.totpEnrollment == nil {
                Button(hasAuthenticator ? "Add authenticator" : "Set up authenticator") {
                    perform { _ = await account.enrollTOTP() }
                }
                .disabled(unavailable || needsVerification)
                .accessibilityIdentifier("account.security.totp.enroll")
            }
        } header: {
            Text("Two-factor authentication")
        }
    }

    private func enrollmentSection(_ enrollment: BoundTOTPEnrollment) -> some View {
        Section {
            Text("Add Bound to your authenticator")
                .font(.headline)
            Text("Scan this code with your authenticator, or enter the setup key manually. Keep the key private.")
            if let qrCode = Self.qrCode(enrollment.uri) {
                HStack {
                    Spacer()
                    Image(uiImage: qrCode).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 200, height: 200).padding(12).background(.white)
                        .accessibilityLabel("Authenticator setup QR code")
                        .accessibilityIdentifier("account.security.totp.qr")
                    Spacer()
                }
                .privacySensitive()
            }
            Text(enrollment.secret)
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .privacySensitive()
                .accessibilityLabel("Authenticator setup key")
                .accessibilityIdentifier("account.security.totp.secret")
            BoundAuthenticatorCodeField(code: $enrollmentCode, identifier: "account.security.totp.code") {
                verifyEnrollment()
            }
            .disabled(unavailable)
            Button("Verify and enable") { verifyEnrollment() }
                .disabled(unavailable || enrollmentCode.count != 6)
                .accessibilityIdentifier("account.security.totp.verify")
            Button("Cancel setup", role: .cancel) {
                enrollmentCode = ""
                perform { await account.cancelTOTPEnrollment() }
            }
            .disabled(unavailable)
            .accessibilityIdentifier("account.security.totp.cancel")
        } header: {
            Text("Complete authenticator setup")
        } footer: {
            Text("Enter the current six-digit code from the authenticator you just added.")
        }
    }

    private var verificationSection: some View {
        Section {
            if verifiedAuthenticators.count > 1 {
                Picker("Authenticator", selection: Binding(
                    get: { selectedFactorID ?? verifiedAuthenticators.first?.id ?? "" },
                    set: { selectedFactorID = $0; verificationCode = "" }
                )) {
                    ForEach(Array(verifiedAuthenticators.enumerated()), id: \.element.id) { index, factor in
                        Text(factor.friendlyName.isEmpty ? "Authenticator \(index + 1)" : factor.friendlyName).tag(factor.id)
                    }
                }
                .disabled(unavailable)
                .accessibilityIdentifier("account.security.step-up.factor")
            }
            BoundAuthenticatorCodeField(code: $verificationCode, identifier: "account.security.step-up.code") {
                verifyCurrentSession()
            }
            .disabled(unavailable)
            Button("Verify authenticator") { verifyCurrentSession() }
                .disabled(unavailable || verificationCode.count != 6)
                .accessibilityIdentifier("account.security.step-up.verify")
        } header: {
            Text("Verify your identity")
        }
    }

    private var passkeysSection: some View {
        Section {
            if account.passkeys.isEmpty {
                Text("No passkeys added").foregroundStyle(.secondary)
                    .accessibilityIdentifier("account.security.passkeys.empty")
            }
            ForEach(account.passkeys) { passkey in
                HStack {
                    Text(passkey.name.isEmpty ? "Passkey" : passkey.name)
                    Spacer()
                    Button("Remove", role: .destructive) { passkeyToRemove = passkey.id }
                        .disabled(unavailable || needsVerification)
                        .accessibilityLabel("Remove \(passkey.name.isEmpty ? "passkey" : passkey.name)")
                        .accessibilityIdentifier("account.security.passkey.remove.\(passkey.id)")
                }
            }
            if account.passkeysAvailable {
                Button("Add passkey") {
                    perform { _ = await account.registerPasskey(name: "") }
                }
                .disabled(unavailable || needsVerification)
                .accessibilityIdentifier("account.security.passkey.add")
            } else {
                Text("Passkeys are not available for this account service yet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("account.security.passkeys.unavailable")
            }
        } header: {
            Text("Passkeys")
        }
    }

    private func verifyEnrollment() {
        guard !unavailable, enrollmentCode.count == 6 else { return }
        let code = enrollmentCode; enrollmentCode = ""
        perform { _ = await account.verifyTOTPEnrollment(code: code) }
    }

    private func verifyCurrentSession() {
        guard !unavailable, verificationCode.count == 6 else { return }
        let code = verificationCode; verificationCode = ""
        let factorID = selectedFactorID
        perform { _ = await account.verifySecondFactor(code: code, factorID: factorID) }
    }

    private func perform(_ action: @escaping @MainActor () async -> Void) {
        guard !unavailable else { return }
        let run = UUID(); operationID = run
        submission = Task { @MainActor in
            await action()
            if operationID == run { submission = nil }
        }
    }

    private func clearInputs() {
        enrollmentCode = ""; verificationCode = ""; selectedFactorID = nil
        factorToRemove = nil; passkeyToRemove = nil
    }

    private static func qrCode(_ value: String) -> UIImage? {
        guard value.utf8.count <= 8192,
              let url = URL(string: value), url.scheme == "otpauth", url.host == "totp" else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let rendered = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: rendered)
    }
}

/// Inline continuation of password sign-in; the model does not publish an AAL1 session.
struct BoundAccountSecondFactorSignInView: View {
    @ObservedObject var account: BoundFriendAccount
    var signedIn: () -> Void = {}
    @State private var code = ""
    @State private var selectedFactorID: String?
    @State private var submission: Task<Void, Never>?
    @State private var operationID = UUID()

    private var verifiedAuthenticators: [BoundSecurityFactor] {
        account.securityFactors.filter { $0.factorType == "totp" && $0.status == "verified" }
    }

    var body: some View {
        Group {
            if !verifiedAuthenticators.isEmpty {
                Text("Enter the six-digit code from your authenticator to finish signing in.")
                    .font(.caption).foregroundStyle(.secondary)
                if verifiedAuthenticators.count > 1 {
                    Picker("Authenticator", selection: Binding(
                        get: { selectedFactorID ?? verifiedAuthenticators.first?.id ?? "" },
                        set: { selectedFactorID = $0; code = "" }
                    )) {
                        ForEach(Array(verifiedAuthenticators.enumerated()), id: \.element.id) { index, factor in
                            Text(factor.friendlyName.isEmpty ? "Authenticator \(index + 1)" : factor.friendlyName).tag(factor.id)
                        }
                    }
                    .disabled(account.securityBusy || submission != nil)
                    .accessibilityIdentifier("account.signin.second-factor.factor")
                }
                BoundAuthenticatorCodeField(code: $code, identifier: "account.signin.second-factor.code") { verify() }
                    .disabled(account.securityBusy)
                Button("Verify and sign in") { verify() }
                    .disabled(account.securityBusy || submission != nil || code.count != 6)
                    .accessibilityIdentifier("account.signin.second-factor.verify")
            } else {
                Text("Additional verification is required. Sign in with a client that supports your account's verification method.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Cancel sign-in", role: .cancel) {
                operationID = UUID()
                submission?.cancel(); submission = nil; code = ""; selectedFactorID = nil
                account.cancelPendingMFA()
            }
            .accessibilityIdentifier("account.signin.second-factor.cancel")
            if account.securityBusy { ProgressView("Verifying code…") }
            if !account.securityStatus.isEmpty {
                Text(account.securityStatus).font(.caption)
                    .accessibilityIdentifier("account.signin.second-factor.status")
            }
        }
        .onChange(of: account.securityIdentityID) { _ in
            operationID = UUID()
            submission?.cancel(); submission = nil; code = ""; selectedFactorID = nil
        }
        .onChange(of: verifiedAuthenticators.map(\.id)) { ids in
            code = ""
            if let id = selectedFactorID, !ids.contains(id) { selectedFactorID = nil }
        }
        .onDisappear { operationID = UUID(); submission?.cancel(); submission = nil; code = ""; selectedFactorID = nil }
    }

    private func verify() {
        guard !account.securityBusy, submission == nil, code.count == 6 else { return }
        let entered = code; code = ""
        let factorID = selectedFactorID
        let run = UUID(); operationID = run
        submission = Task { @MainActor in
            if await account.verifySecondFactor(code: entered, factorID: factorID), !Task.isCancelled { signedIn() }
            if operationID == run { submission = nil }
        }
    }
}

private struct BoundAuthenticatorCodeField: View {
    @Binding var code: String
    var identifier: String
    var submitted: () -> Void

    var body: some View {
        TextField("Authenticator code", text: $code)
            .textContentType(.oneTimeCode).keyboardType(.numberPad)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .submitLabel(.done).onSubmit(submitted)
            .privacySensitive()
            .onChange(of: code) { value in
                let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                if digits != value { code = digits }
            }
            .accessibilityIdentifier(identifier)
    }
}
