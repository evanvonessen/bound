import Foundation

/// A bounded observation FIFO and a separately serialized immutable writer.
/// Candidates may replace older pending candidates only because the reducer
/// retains all facts/history from every accepted input in the newest value.
final class BoundSDKObservationPipeline<Input: Sendable, Candidate: Sendable>: @unchecked Sendable {
    enum Failure: Error { case timeout, rejected, reduction }
    struct Status {
        let queued: Int, accepted: UInt64, durable: UInt64
        let writing: Bool, failed: Bool
        var drained: Bool { queued == 0 && !writing && !failed && accepted == durable }
    }
    private let compute = DispatchQueue(label: "bound.observation.compute", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let persistence = DispatchQueue(label: "bound.observation.persistence", qos: .utility, autoreleaseFrequency: .workItem)
    private let key = DispatchSpecificKey<Bool>()
    private let condition = NSCondition()
    private let capacity: Int
    private var queued = 0, accepted: UInt64 = 0, durable: UInt64 = 0
    private var writing = false, pressured = false
    private var error: Error?
    private var submitted:UInt64=0,reduced:UInt64=0,rejected:UInt64=0,highWater=0,computeNanoseconds:UInt64=0
    // The following values belong exclusively to compute.
    private var latest: (UInt64, Candidate)?
    private var failedInputs: [Input] = []
    private var modelFailure: Error?
    private let reduce: (Input) throws -> Void
    private let candidate: () throws -> Candidate?
    private let write: (Candidate) throws -> Void
    private let committed: (Candidate) -> Void
    private let failed: (Error) -> Void
    private let backpressure: () -> Void
    private final class FlushCut: @unchecked Sendable { var target: UInt64 = 0 }

    init(capacity: Int = 32, reduce: @escaping (Input) throws -> Void,
         candidate: @escaping () throws -> Candidate?, write: @escaping (Candidate) throws -> Void,
         committed: @escaping (Candidate) -> Void, failed: @escaping (Error) -> Void,
         backpressure: @escaping () -> Void) {
        precondition(capacity > 0)
        self.capacity = capacity; self.reduce = reduce; self.candidate = candidate
        self.write = write; self.committed = committed; self.failed = failed; self.backpressure = backpressure
        compute.setSpecific(key: key, value: true)
    }

    var isComputing: Bool { DispatchQueue.getSpecific(key: key) == true }
    func inspect<T>(_ body: () -> T) -> T { isComputing ? body():compute.sync(execute:body) }
    func perform<T>(_ body: () throws -> T) rethrows -> T {
        if isComputing { return try body() }
        return try compute.sync {
            let result = try body()
            self.stage()
            return result
        }
    }
    @discardableResult func submit(_ input: Input) -> Bool {
        condition.lock()
        // One final immutable observation is retained while the owner closes
        // native frame admission. Subsequent frozen callbacks must not submit
        // duplicate observations or reopen the fence on their own.
        guard queued < capacity + 1 else { rejected &+= 1;condition.unlock(); backpressure(); return false }
        queued += 1;submitted &+= 1;highWater=max(highWater,queued)
        let close = queued > capacity && !pressured
        pressured = pressured || close
        // Enqueue while admission is locked, so a concurrent checkpoint cut
        // cannot overtake an input already counted as accepted.
        compute.async { [self] in
            let start=DispatchTime.now().uptimeNanoseconds
            var retained = false
            if failedInputs.isEmpty && modelFailure == nil {
                do { try reduce(input); stage() }
                catch { failedInputs.append(input); retained = true; record(error) }
            } else { failedInputs.append(input); retained = true }
            condition.lock()
            if !retained { queued -= 1;reduced &+= 1 }
            computeNanoseconds &+= DispatchTime.now().uptimeNanoseconds-start
            condition.broadcast(); condition.unlock()
        }
        condition.unlock()
        if close { backpressure() }
        return true
    }
    private func stage() {
        guard failedInputs.isEmpty,modelFailure == nil else { return }
        let value:Candidate
        do { guard let next=try candidate() else { return };value=next }
        catch { modelFailure=error;record(error);return }
        condition.lock(); accepted &+= 1; let revision = accepted; condition.unlock()
        latest = (revision, value)
        scheduleWrite()
    }
    private func scheduleWrite() {
        guard let (revision, value) = latest else { return }
        condition.lock()
        guard !writing else { condition.unlock(); return }
        writing = true; condition.unlock()
        persistence.async { [self] in
            let result = Result { try write(value) }
            compute.async { [self] in
                switch result {
                case .success:
                    committed(value)
                    condition.lock(); durable = revision; writing = false
                    if failedInputs.isEmpty && modelFailure == nil { error = nil }
                    condition.broadcast(); condition.unlock()
                    if latest?.0 == revision { latest = nil }
                    else { scheduleWrite() }
                case .failure(let failure):
                    condition.lock(); writing = false; condition.unlock()
                    // Retain the aggregate. A new observation or explicit
                    // flush retries it; never spin on an unavailable writer.
                    record(failure)
                }
            }
        }
    }
    private func record(_ failure: Error) {
        condition.lock(); error = failure; condition.broadcast(); condition.unlock()
        failed(failure)
    }
    func status() -> Status {
        condition.lock(); defer { condition.unlock() }
        return .init(queued: queued, accepted: accepted, durable: durable, writing: writing, failed: error != nil)
    }
    func metrics()->[String:UInt64] {
        condition.lock();defer { condition.unlock() }
        return ["admitted":submitted,"reduced":reduced,"rejected":rejected,"highWater":UInt64(highWater),
                "computeNanoseconds":computeNanoseconds,"queued":UInt64(queued)]
    }
    /// Call with the native owner paused. Waiting never holds the reducer or
    /// publication lock, and a timeout leaves every pending value intact.
    func flush(timeout: TimeInterval = 5) throws {
        precondition(!isComputing)
        let duration = max(0, timeout), deadline = Date().addingTimeInterval(duration)
        let barrier = DispatchSemaphore(value: 0), cut = FlushCut()
        condition.lock()
        compute.async { [self] in
            if failedInputs.isEmpty && modelFailure == nil {
                condition.lock(); error = nil; condition.unlock()
                stage(); scheduleWrite()
            }
            condition.lock(); cut.target = accepted; condition.unlock()
            barrier.signal()
        }
        condition.unlock()
        guard barrier.wait(timeout: .now() + duration) == .success else { throw Failure.timeout }
        condition.lock(); defer { condition.unlock() }
        while durable < cut.target || writing || queued > 0 {
            if let error { throw error }
            guard condition.wait(until: deadline) else { throw Failure.timeout }
        }
        if let error { throw error }
        pressured = false
    }
}
