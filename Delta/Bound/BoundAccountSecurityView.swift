import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

/// Optional account security belongs to the Bound account, independently of device sync.
struct BoundAccountSecurityView: View {
    @ObservedObject var account: BoundFriendAccount
    var emailChanged: (String) -> Void = { _ in }
    @State private var enrollmentCode = ""
    @State private var verificationCode = ""
    @State private var selectedFactorID: String?
    @State private var submission: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var factorToRemove: String?
    @State private var showingEmailChange = false

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
                Section { Text("Sign in to manage your account.") }
            } else {
                Section("Account") {
                    NavigationLink("Change username") {
                        BoundUsernameSettings().boundSettingsPage()
                    }
                    .disabled(unavailable || account.changingEmail)
                    .accessibilityIdentifier("bound.account-username")
                    BoundAccountEmailText(account: account) { showingEmailChange = true }
                    BoundAccountPasswordResetLink(account: account)
                }
                authenticatorSection
                if let enrollment = account.totpEnrollment {
                    enrollmentSection(enrollment)
                }
                if needsVerification { verificationSection }
                if account.securityBusy { Section { ProgressView("Updating account security…") } }
                if !account.securityStatus.isEmpty {
                    Section {
                        Text(account.securityStatus)
                            .accessibilityIdentifier("account.security.status")
                    }
                }
            }
        }
        .navigationTitle("Account and Security")
        .navigationBarTitleDisplayMode(.inline)
        .boundSettingsPage()
        .sheet(isPresented: $showingEmailChange) {
            BoundChangeEmailView(account: account, emailChanged: emailChanged)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .task(id: account.securityIdentityID) {
            operationID = UUID(); submission?.cancel(); submission = nil
            clearInputs()
            await account.loadAccountSecurity()
        }
        .onChange(of: verifiedAuthenticators.map(\.id)) { _, ids in
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
            Text("Two-Factor Authentication")
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
            Text("Complete Authenticator Setup")
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
            Text("Verify Your Identity")
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
        factorToRemove = nil
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
        .onChange(of: account.securityIdentityID) {
            operationID = UUID()
            submission?.cancel(); submission = nil; code = ""; selectedFactorID = nil
        }
        .onChange(of: verifiedAuthenticators.map(\.id)) { _, ids in
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
            .onChange(of: code) { _, value in
                let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                if digits != value { code = digits }
            }
            .accessibilityIdentifier(identifier)
    }
}
