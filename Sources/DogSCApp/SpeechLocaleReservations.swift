import Foundation
import Speech

/// Apple locale reservations are shared by every analyzer in this app. A
/// session owns a lease rather than assuming its reserve() call is the only
/// active use of that locale (memo following can overlap subtitle generation).
actor SpeechLocaleReservations {
    typealias Reserve = @Sendable (Locale) async throws -> Bool
    typealias Release = @Sendable (Locale) async -> Void

    @available(macOS 26, *)
    static let shared = SpeechLocaleReservations(
        reserve: { try await AssetInventory.reserve(locale: $0) },
        release: { _ = await AssetInventory.release(reservedLocale: $0) }
    )

    private struct Entry {
        let id: UUID
        let locale: Locale
        let reservation: Task<Bool, any Error>
        var users: Set<UUID>
        var cleanup: Task<Void, Never>?
    }

    private let reserve: Reserve
    private let release: Release
    private var entries: [String: Entry] = [:]

    init(reserve: @escaping Reserve, release: @escaping Release) {
        self.reserve = reserve
        self.release = release
    }

    func acquire(locale: Locale) async throws -> SpeechLocaleLease {
        try Task.checkCancellation()
        let key = locale.identifier
        // A new user must wait until the previous final release finishes.
        // Otherwise it could join just before release() unreserves the locale.
        while let entry = entries[key], let cleanup = entry.cleanup {
            await cleanup.value
            if entries[key]?.id == entry.id { entries.removeValue(forKey: key) }
            try Task.checkCancellation()
        }
        let token = UUID()
        let reservation: Task<Bool, any Error>
        if var entry = entries[key] {
            entry.users.insert(token)
            entries[key] = entry
            reservation = entry.reservation
        } else {
            let reserve = self.reserve
            reservation = Task { try await reserve(locale) }
            entries[key] = Entry(id: UUID(), locale: locale, reservation: reservation,
                users: [token], cleanup: nil)
        }
        do {
            _ = try await reservation.value
            try Task.checkCancellation()
            return SpeechLocaleLease { [self] in await releaseToken(token, key: key) }
        } catch {
            await releaseToken(token, key: key)
            throw error
        }
    }

    private func releaseToken(_ token: UUID, key: String) async {
        guard var entry = entries[key], entry.users.remove(token) != nil else { return }
        if !entry.users.isEmpty { entries[key] = entry; return }
        let release = self.release
        let reservation = entry.reservation
        let locale = entry.locale
        let cleanup = Task {
            // A pre-existing reservation can belong to another app component
            // or framework. Only release a reservation this registry acquired.
            if (try? await reservation.value) == true { await release(locale) }
        }
        entry.cleanup = cleanup
        entries[key] = entry
        await cleanup.value
        if entries[key]?.id == entry.id { entries.removeValue(forKey: key) }
    }
}

final class SpeechLocaleLease: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseAction: @Sendable () async -> Void
    private var cleanup: Task<Void, Never>?

    init(release: @escaping @Sendable () async -> Void) { releaseAction = release }

    func release() async {
        let task = lock.withLock {
            if let cleanup { return cleanup }
            let action = releaseAction
            let task = Task { await action() }
            cleanup = task
            return task
        }
        await task.value
    }
}
