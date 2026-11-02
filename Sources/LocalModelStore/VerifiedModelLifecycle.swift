import Foundation

/// Process-scoped lifecycle for model installations admitted by `LocalModelStore`.
///
/// Only successful full-manifest SHA-256 verification is cached, and only while
/// the files keep the fingerprint they were hashed with, so another process's
/// change is noticed. Missing or corrupt results are deliberately rechecked, and
/// explicit install, removal, or invalidation prevents an older in-flight check
/// from restoring stale evidence.
public actor VerifiedModelLifecycle {
    typealias VerificationOperation = @Sendable (
        ModelManifest
    ) async -> LocalModelStore.VerifiedInstallation?
    typealias InstallationOperation = @Sendable (
        ModelManifest,
        (@Sendable (LocalModelStore.InstallEvent) -> Void)?
    ) async throws -> LocalModelStore.VerifiedInstallation
    typealias RemovalOperation = @Sendable (ModelManifest, LocalModelStore.RemovalScope) async throws
        -> LocalModelStore.RemovalOutcome
    typealias CurrencyOperation = @Sendable (ModelManifest) async -> Bool

    private struct Verification: Sendable {
        let generation: UUID
        let task: Task<LocalModelStore.VerifiedInstallation?, Never>
    }

    private struct Mutation: Sendable {
        let generation: UUID
        let completion: Task<Void, Never>
    }

    private let verifyInstallation: VerificationOperation
    private let installModel: InstallationOperation
    private let removeModel: RemovalOperation
    private let evidenceIsCurrent: CurrencyOperation
    private var verified: [String: LocalModelStore.VerifiedInstallation] = [:]
    private var verifications: [String: Verification] = [:]
    private var mutations: [String: Mutation] = [:]

    /// `seeds` names read-only directories to reuse for a manifest, such as a legacy install.
    public init(store: LocalModelStore, seeds: @escaping @Sendable (ModelManifest) -> [URL] = { _ in [] }) {
        verifyInstallation = { manifest in
            // This actor owns the fast path, so reaching the store always means a full hash.
            await store.verifiedInstallation(manifest, forceHash: true)
        }
        installModel = { manifest, progress in
            let directory = try await store.ensureAvailable(manifest, seeds: seeds(manifest), progress: progress)
            return LocalModelStore.VerifiedInstallation(
                manifestID: manifest.id,
                manifestRevision: manifest.revision,
                directory: directory,
                artifactBytes: Int64(manifest.totalSizeBytes))
        }
        removeModel = { manifest, scope in
            try await store.remove(manifest, scope: scope)
        }
        evidenceIsCurrent = { manifest in
            await store.fingerprintIsCurrent(manifest)
        }
    }

    init(
        verifyInstallation: @escaping VerificationOperation,
        installModel: @escaping InstallationOperation,
        removeModel: @escaping RemovalOperation,
        evidenceIsCurrent: @escaping CurrencyOperation = { _ in true }
    ) {
        self.verifyInstallation = verifyInstallation
        self.installModel = installModel
        self.removeModel = removeModel
        self.evidenceIsCurrent = evidenceIsCurrent
    }

    public func installation(
        for manifest: ModelManifest,
        forceVerification: Bool = false
    ) async -> LocalModelStore.VerifiedInstallation? {
        let key = Self.key(for: manifest)
        if forceVerification {
            invalidateEvidence(key: key)
        }
        var requiresVerification = forceVerification

        while true {
            if let mutation = mutations[key] {
                await mutation.completion.value
                continue
            }
            if !requiresVerification, let cached = verified[key] {
                let current = await evidenceIsCurrent(manifest)
                // The await may have crossed a mutation or invalidation.
                guard verified[key] == cached, mutations[key] == nil else { continue }
                if current { return cached }
                verified[key] = nil
            }

            let verification: Verification
            if let current = verifications[key] {
                verification = current
            } else {
                let generation = UUID()
                let verifyInstallation = verifyInstallation
                let task = Task {
                    await verifyInstallation(manifest)
                }
                verification = Verification(generation: generation, task: task)
                verifications[key] = verification
            }

            let installation = await verification.task.value
            guard verifications[key]?.generation == verification.generation else {
                // A mutation or explicit invalidation superseded this result.
                // Loop until the caller receives evidence for current state.
                requiresVerification = false
                continue
            }
            verifications[key] = nil
            verified[key] = installation
            return installation
        }
    }

    public func install(
        _ manifest: ModelManifest,
        progress: (@Sendable (LocalModelStore.InstallEvent) -> Void)? = nil
    ) async throws -> LocalModelStore.VerifiedInstallation {
        let key = Self.key(for: manifest)
        invalidateEvidence(key: key)
        let previous = mutations[key]?.completion
        let generation = UUID()
        let installModel = installModel
        let task = Task {
            await previous?.value
            do {
                try Task.checkCancellation()
                let installation = try await installModel(manifest, progress)
                // Installation has crossed its filesystem commit point. A
                // cancellation arriving now must not report false failure.
                completeInstall(
                    installation,
                    key: key,
                    generation: generation)
                return installation
            } catch {
                completeMutation(key: key, generation: generation)
                throw error
            }
        }
        let completion = Task {
            _ = try? await task.value
        }
        mutations[key] = Mutation(generation: generation, completion: completion)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @discardableResult
    public func remove(
        _ manifest: ModelManifest,
        scope: LocalModelStore.RemovalScope = .thisConsumer
    ) async throws -> LocalModelStore.RemovalOutcome {
        let key = Self.key(for: manifest)
        invalidateEvidence(key: key)
        let previous = mutations[key]?.completion
        let generation = UUID()
        let removeModel = removeModel
        let task = Task {
            await previous?.value
            do {
                try Task.checkCancellation()
                let outcome = try await removeModel(manifest, scope)
                completeMutation(key: key, generation: generation)
                return outcome
            } catch {
                completeMutation(key: key, generation: generation)
                throw error
            }
        }
        let completion = Task {
            _ = try? await task.value
        }
        mutations[key] = Mutation(generation: generation, completion: completion)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func invalidate(_ manifest: ModelManifest) {
        invalidateEvidence(key: Self.key(for: manifest))
    }

    private func invalidateEvidence(key: String) {
        verified[key] = nil
        verifications[key]?.task.cancel()
        verifications[key] = nil
    }

    private func completeInstall(
        _ installation: LocalModelStore.VerifiedInstallation,
        key: String,
        generation: UUID
    ) {
        guard mutations[key]?.generation == generation else { return }
        verified[key] = installation
        mutations[key] = nil
    }

    private func completeMutation(key: String, generation: UUID) {
        guard mutations[key]?.generation == generation else { return }
        mutations[key] = nil
    }

    private static func key(for manifest: ModelManifest) -> String {
        manifest.evidenceKey
    }
}
