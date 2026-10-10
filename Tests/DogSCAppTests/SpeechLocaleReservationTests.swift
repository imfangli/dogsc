import Foundation
import XCTest
@testable import DogSCApp

@MainActor
final class SpeechLocaleReservationTests: XCTestCase {
    func testConcurrentSessionsShareReservationUntilLastRelease() async throws {
        let inventory = SubtitleFakeLocaleInventory()
        let registry = registry(inventory)
        let locale = Locale(identifier: "zh-CN")
        let leases = try await withThrowingTaskGroup(of: SpeechLocaleLease.self) { group in
            for _ in 0..<32 { group.addTask { try await registry.acquire(locale: locale) } }
            var leases: [SpeechLocaleLease] = []
            for try await lease in group { leases.append(lease) }
            return leases
        }
        var counts = await inventory.counts()
        XCTAssertEqual(counts.reserves, 1)
        XCTAssertEqual(counts.releases, 0)
        await withTaskGroup(of: Void.self) { group in
            for lease in leases.dropLast() { group.addTask { await lease.release() } }
        }
        counts = await inventory.counts()
        XCTAssertEqual(counts.releases, 0)
        let last = try XCTUnwrap(leases.last)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 { group.addTask { await last.release() } }
        }
        counts = await inventory.counts()
        XCTAssertEqual(counts.releases, 1)
    }

    func testExternallyOwnedReservationIsNeverReleased() async throws {
        let inventory = SubtitleFakeLocaleInventory(alreadyReserved: true)
        let registry = registry(inventory)
        let first = try await registry.acquire(locale: Locale(identifier: "zh-CN"))
        let second = try await registry.acquire(locale: Locale(identifier: "zh-CN"))
        await first.release()
        await second.release()
        let counts = await inventory.counts()
        XCTAssertEqual(counts.reserves, 1)
        XCTAssertEqual(counts.releases, 0)
    }

    func testCancellationWhileReserveIsPendingDoesNotReleaseOtherUser() async throws {
        let inventory = SubtitleFakeLocaleInventory(reserveDelay: .milliseconds(80))
        let registry = registry(inventory)
        let locale = Locale(identifier: "zh-CN")
        let cancelled = Task { try await registry.acquire(locale: locale) }
        let survivor = Task { try await registry.acquire(locale: locale) }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Pending acquire ignored cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let lease = try await survivor.value
        var counts = await inventory.counts()
        XCTAssertEqual(counts.reserves, 1)
        XCTAssertEqual(counts.releases, 0)
        await lease.release()
        counts = await inventory.counts()
        XCTAssertEqual(counts.releases, 1)
    }

    func testNewAcquireWaitsForPreviousFinalRelease() async throws {
        let inventory = SubtitleFakeLocaleInventory(releaseDelay: .milliseconds(80))
        let registry = registry(inventory)
        let locale = Locale(identifier: "zh-CN")
        let first = try await registry.acquire(locale: locale)
        let releasing = Task { await first.release() }
        for _ in 0..<20 {
            if await inventory.isReleasing { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let second = try await registry.acquire(locale: locale)
        await releasing.value
        let before = await inventory.counts()
        XCTAssertEqual(before.reserves, 2)
        XCTAssertEqual(before.releases, 1)
        await second.release()
        let after = await inventory.counts()
        XCTAssertEqual(after.releases, 2)
    }

    func testFailedReserveCanBeRetriedWithoutLeakingUse() async throws {
        let inventory = SubtitleFakeLocaleInventory(failFirstReserve: true)
        let registry = registry(inventory)
        do {
            _ = try await registry.acquire(locale: Locale(identifier: "zh-CN"))
            XCTFail("Expected failed reservation")
        } catch { XCTAssertEqual(error as? SubtitleFakeLocaleInventory.Failure, .reserveFailed) }
        let lease = try await registry.acquire(locale: Locale(identifier: "zh-CN"))
        await lease.release()
        let counts = await inventory.counts()
        XCTAssertEqual(counts.reserves, 2)
        XCTAssertEqual(counts.releases, 1)
    }

    private func registry(_ inventory: SubtitleFakeLocaleInventory) -> SpeechLocaleReservations {
        SpeechLocaleReservations(reserve: { try await inventory.reserve($0) },
            release: { await inventory.release($0) })
    }
}

private actor SubtitleFakeLocaleInventory {
    enum Failure: Error { case reserveFailed, reservedDuringRelease }
    private var reserved: Bool
    private var reserveCount = 0
    private var releaseCount = 0
    private let reserveDelay: Duration
    private let releaseDelay: Duration
    private let failFirstReserve: Bool
    private(set) var isReleasing = false

    init(alreadyReserved: Bool = false, reserveDelay: Duration = .zero,
        releaseDelay: Duration = .zero, failFirstReserve: Bool = false) {
        reserved = alreadyReserved
        self.reserveDelay = reserveDelay
        self.releaseDelay = releaseDelay
        self.failFirstReserve = failFirstReserve
    }

    func reserve(_ locale: Locale) async throws -> Bool {
        guard !isReleasing else { throw Failure.reservedDuringRelease }
        reserveCount += 1
        if failFirstReserve && reserveCount == 1 { throw Failure.reserveFailed }
        try await Task.sleep(for: reserveDelay)
        let owns = !reserved
        reserved = true
        return owns
    }

    func release(_ locale: Locale) async {
        isReleasing = true
        try? await Task.sleep(for: releaseDelay)
        releaseCount += 1
        reserved = false
        isReleasing = false
    }

    func counts() -> (reserves: Int, releases: Int) { (reserveCount, releaseCount) }
}
