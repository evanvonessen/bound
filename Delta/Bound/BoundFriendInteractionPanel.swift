import UIKit
import DeltaCore

/// A bounded completed-frame mailbox. Neither the UI nor network callbacks touch
/// guest memory; replacing a request first lets native B dismiss the old window.
final class BoundFriendDialogueProbe: @unchecked Sendable {
    struct Request: Equatable { let id: UUID; let mode: Int; let text: String }
    struct Reading {
        var id: UUID?; var activeID: UUID?; var result: Int?
        var ready=false; var active=false; var menuReady=false; var mode = -1; var cursor = -1
        func permitsNativeInput(pending: Bool, acknowledgingEnd: Bool) -> Bool {
            // While entry waits on native dialogue, its own A/B handling must
            // remain available so that dialogue can finish and release entry.
            active ? menuReady : !ready && (pending || acknowledgingEnd)
        }
    }
    private let lock=NSLock()
    private var coreID: ObjectIdentifier?
    private var desired: Request?, current: Request?
    private var reading=Reading()
    private var reported=false, needsOwnerReset=true
    func configure(core: EmulatorCore?) {
        lock.lock(); defer { lock.unlock() }
        coreID=core?.deltaCore.identifier == "com.rileytestut.GBADeltaCore" ? core.map(ObjectIdentifier.init):nil; desired=nil; current=nil; reading=Reading(); reported=false; needsOwnerReset=true
    }
    func show(_ value: Request?) { lock.lock(); desired=value; lock.unlock() }
    func read() -> Reading { lock.lock(); defer { lock.unlock() }; return reading }
    func receive(_ core: EmulatorCore) {
        lock.lock(); defer { lock.unlock() }
        guard coreID==ObjectIdentifier(core) else { return }
        if needsOwnerReset { BoundVBABattleBridge.resetFriendDialogueOwner(); needsOwnerReset=false }
        var native=BoundVBABattleBridge.advanceFriendDialogue()
        if let current, desired?.id != current.id, native["active"] as? Bool == true {
            BoundVBABattleBridge.cancelFriendDialogue()
        }
        if let current, native["active"] as? Bool != true {
            let result=native["result"] as? Int ?? -2
            if !reported, desired?.id==current.id {
                reading.id=current.id; reading.result=result; reported=true
            }
            self.current=nil
        }
        if current==nil, let desired, reading.id != desired.id, native["ready"] as? Bool == true {
            if BoundVBABattleBridge.beginFriendDialogue(UInt(desired.mode),text:desired.text) {
                current=desired; reported=false
                native=BoundVBABattleBridge.advanceFriendDialogue()
            } else {
                reading.id=desired.id; reading.result = -3
            }
        }
        reading.ready=native["ready"] as? Bool ?? false
        reading.active=native["active"] as? Bool ?? false
        reading.activeID=reading.active ? current?.id:nil
        reading.menuReady=native["menuReady"] as? Bool ?? false
        reading.mode=native["mode"] as? Int ?? -1
        reading.cursor=native["cursor"] as? Int ?? -1
    }
}

/// Pending invitations use a compact notification. Opening it is an explicit
/// request for a native menu; only native cleanup releases that menu's ownership.
@MainActor
final class BoundFriendInteractionPanel: UIView {
    let probe=BoundFriendDialogueProbe()
    private weak var session: BoundFriendInteractionSession?
    var name: (() -> String)?
    var willOpen: (() -> Void)?
    private var phase: BoundFriendInteractionSession.Phase = .idle
    private var request: BoundFriendDialogueProbe.Request?
    private var closeCompletion: (() -> Void)?
    private var timer: Timer?
    private var boundCore: ObjectIdentifier?
    private var configured=false
    private var shownMessage=""
    private var waitingForConnection=false
    private var menuPresented=false
    private let invitationButton=UIButton(type:.system)
    private let cancelButton=UIButton(type:.system)
    private let pendingBar=UIStackView()
    init(session: BoundFriendInteractionSession) {
        self.session=session
        super.init(frame:.zero)
        isHidden=true; isUserInteractionEnabled=true
        autoresizingMask=[.flexibleWidth,.flexibleHeight]
        accessibilityIdentifier="bound.friend-interaction"
        invitationButton.configuration = .tinted()
        invitationButton.accessibilityIdentifier="bound.friend-invitation-open"
        invitationButton.addAction(UIAction { [weak self] _ in _ = self?.session?.open() }, for:.touchUpInside)
        cancelButton.configuration = .tinted()
        cancelButton.setImage(UIImage(systemName:"xmark"),for:.normal)
        cancelButton.accessibilityLabel="Cancel invitation"
        cancelButton.accessibilityIdentifier="bound.friend-invitation-cancel"
        cancelButton.addAction(UIAction { [weak self] _ in self?.session?.cancel() }, for:.touchUpInside)
        pendingBar.axis = .horizontal; pendingBar.spacing=4
        pendingBar.addArrangedSubview(invitationButton); pendingBar.addArrangedSubview(cancelButton)
        addSubview(pendingBar); pendingBar.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([
            pendingBar.topAnchor.constraint(equalTo:safeAreaLayoutGuide.topAnchor,constant:8),
            pendingBar.trailingAnchor.constraint(equalTo:safeAreaLayoutGuide.trailingAnchor,constant:-8),
            pendingBar.leadingAnchor.constraint(greaterThanOrEqualTo:safeAreaLayoutGuide.leadingAnchor,constant:8),
            pendingBar.widthAnchor.constraint(lessThanOrEqualToConstant:240),
            cancelButton.widthAnchor.constraint(equalToConstant:36)
        ])
        session.beforeAgreement={ [weak self] completion in
            guard let self else { return }
            self.closeCompletion=completion; self.probe.show(nil)
        }
    }
    @available(*,unavailable) required init?(coder:NSCoder) { fatalError("Use init(session:)") }
    override func hitTest(_ point:CGPoint,with event:UIEvent?)->UIView? {
        guard !isHidden else { return nil }
        return pendingBar.hitTest(convert(point,to:pendingBar),with:event)
    }
    func bind(core: EmulatorCore?) {
        let id=core.map(ObjectIdentifier.init)
        guard !configured || boundCore != id else { return }
        configured=true; boundCore=id; closeCompletion=nil; request=nil; phase = .idle; waitingForConnection=false;menuPresented=false
        let supported=core?.deltaCore.identifier == "com.rileytestut.GBADeltaCore"
        probe.configure(core:supported ? core:nil)
        session?.nativeDialogueManaged=supported
        session?.nativeDialogueReady=false
        session?.nativeDialogueBusy=false
        session?.nativeDialogueInput=false
        session?.refreshInputGate()
        timer?.invalidate(); timer=nil
        if supported {
            let timer=Timer(timeInterval:0.05,repeats:true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            RunLoop.main.add(timer,forMode:.common); self.timer=timer
            render()
        } else {
            session?.cancel()
        }
    }
    func render() {
        isHidden=true
        guard let session, configured else { return }
        let pending = [.incoming,.outgoing,.confirming,.agreed,.connecting].contains(session.phase) && !session.menuPresented
        if pending {
            let title = [.agreed,.connecting].contains(session.phase) ? session.message : session.phase == .confirming ? "Confirming…" : (session.activity?.title ?? "Friend") + (session.phase == .incoming ? " invitation":" pending")
            invitationButton.setTitle(title,for:.normal)
            invitationButton.isEnabled=session.canInteract
            invitationButton.accessibilityHint="Open invitation menu"
            isHidden=false
        } else if session.phase == .ended && !session.requiresResultAcknowledgement && !session.message.isEmpty {
            invitationButton.setTitle(session.message,for:.normal)
            invitationButton.isEnabled=false
            isHidden=false
        }
        let waiting = session.phase == .agreed && session.waitingForConnection
        if phase != session.phase || phase == .ended && shownMessage != session.message || waiting != waitingForConnection || menuPresented != session.menuPresented {
            waitingForConnection=waiting
            phase=session.phase; shownMessage=session.message;menuPresented=session.menuPresented
            request=nil
            if phase != .agreed { closeCompletion=nil }
            guard menuPresented || phase == .ended && session.requiresResultAcknowledgement || phase == .agreed && waiting else { probe.show(nil); return }
            let mode:Int, text:String
            switch phase {
            case .choosing: mode=0; text="What would you like to do\nwith your friend?"
            case .incoming:
                mode=1; text="Your friend wants to \(session.activity?.rawValue ?? "trade").\nWill you accept?"
            case .outgoing: mode=2; text="Waiting for your friend.\nA or B: Cancel."
            case .confirming: mode=2; text="Confirming with your friend.\nA or B: Cancel."
            case .agreed where waiting: mode=2; text="Waiting for your friend.\nA or B: Cancel."
            case .ended:
                guard session.requiresResultAcknowledgement else { probe.show(nil); return }
                mode=2; text=Self.message(session.message)
            default: probe.show(nil); return
            }
            willOpen?()
            request = .init(id:UUID(),mode:mode,text:text)
            probe.show(request)
        }
    }
    private static func message(_ value:String)->String {
        if value.hasPrefix("Trade interrupted") { return "Trade interrupted.\nContinue your in-game save." }
        if value.contains("Reopen this game") { return "Recovery kept. Reopen this\ngame to continue." }
        if value.contains("unavailable during Soul Link") { return "End Soul Link before\ntrading with friends." }
        // Native text has a 28-column field box. Wrap without control sequences
        // or names supplied by another account; the host's status is bounded.
        let words=value.replacingOccurrences(of:"…",with:"...").replacingOccurrences(of:"’",with:"'").replacingOccurrences(of:"·",with:".").components(separatedBy:.whitespacesAndNewlines)
        var lines=[String](), line=""
        for word in words where !word.isEmpty {
            if line.count+word.count+1>28 { lines.append(line); line="" }
            line += (line.isEmpty ? "":" ")+word
        }
        if !line.isEmpty { lines.append(line) }
        return lines.prefix(2).joined(separator:"\n")
    }
    private func poll() {
        guard let session else { timer?.invalidate(); timer=nil; return }
        let value=probe.read()
        session.nativeDialogueReady=value.ready
        session.nativeDialogueBusy=value.active || request != nil || closeCompletion != nil
        // Consent may arrive while ordinary gameplay has opened an NPC/follower
        // dialogue or menu. Native cleanup needs its own A/B input until field
        // admission is ready; otherwise agreed blocks the input it waits for.
        session.nativeDialogueInput=value.permitsNativeInput(pending: request != nil || closeCompletion != nil, acknowledgingEnd: session.phase == .ended)
        session.refreshInputGate()
        if let closeCompletion,!value.active,value.ready {
            self.closeCompletion=nil; closeCompletion(); return
        }
        guard let request,value.id==request.id,let result=value.result else { return }
        self.request=nil; probe.show(nil)
        if result == -3 { session.cancel(); return }
        guard result >= 0 else { return }
        switch session.phase {
        case .choosing:
            if result==0 { session.request(.battle) }
            else if result==1 { session.request(.trade) }
            else { session.cancel() }
        case .incoming:
            if result==1 { session.accept() } else { session.decline() }
        case .outgoing, .confirming, .agreed, .ended: session.cancel()
        default: break
        }
    }
}
