import Darwin
import XCTest
@testable import Tokenly

/// Disk capacity arithmetic with fixed reads, plus a smoke test against the real system volume.
final class DiskUsageTests: XCTestCase {
    private func usage(_ read: DiskCapacityRead, file: StaticString = #filePath, line: UInt = #line) throws -> DiskUsage {
        try XCTUnwrap(DiskUsage.make(from: read).value, file: file, line: line)
    }

    func testUsedIsTotalMinusAvailableAndPurgeableIsSeparate() throws {
        // Values from Mac16,12 on 2026-10-27: container 245.11 GB, free 52.19 GB, free incl. purgeable 65.90 GB.
        let disk = try usage(.values(total: 245_107_195_904, available: 52_194_562_048, availableForImportantUsage: 65_900_000_000))
        XCTAssertEqual(disk.totalBytes, 245_107_195_904)
        XCTAssertEqual(disk.availableBytes, 52_194_562_048)
        XCTAssertEqual(disk.usedBytes, 192_912_633_856)
        XCTAssertEqual(disk.usedFraction, 192_912_633_856.0 / 245_107_195_904.0, accuracy: 1e-12)
        XCTAssertEqual(disk.availableForImportantUsageBytes, .available(65_900_000_000))
    }

    func testFullAndEmptyDisksAreRealValues() throws {
        let full = try usage(.values(total: 1_000, available: 0, availableForImportantUsage: 0))
        XCTAssertEqual(full.usedFraction, 1)
        XCTAssertEqual(full.availableBytes, 0, "A full disk is a measured 0, not a failure")

        let empty = try usage(.values(total: 1_000, available: 1_000, availableForImportantUsage: 1_000))
        XCTAssertEqual(empty.usedFraction, 0)
        XCTAssertEqual(empty.usedBytes, 0)
    }

    func testReadFailureIsDistinctFromMissingAndImpossibleValues() {
        XCTAssertEqual(DiskUsage.make(from: .failed(EIO)), .unavailable(.readFailed(EIO)))
        XCTAssertEqual(DiskUsage.make(from: .values(total: nil, available: 10, availableForImportantUsage: nil)), .unavailable(.unsupported))
        XCTAssertEqual(DiskUsage.make(from: .values(total: 100, available: nil, availableForImportantUsage: nil)), .unavailable(.unsupported))
        XCTAssertEqual(DiskUsage.make(from: .values(total: 0, available: 0, availableForImportantUsage: nil)), .unavailable(.inconsistentValues))
        XCTAssertEqual(DiskUsage.make(from: .values(total: -5, available: 0, availableForImportantUsage: nil)), .unavailable(.inconsistentValues))
        XCTAssertEqual(DiskUsage.make(from: .values(total: 100, available: -1, availableForImportantUsage: nil)), .unavailable(.inconsistentValues))
        XCTAssertEqual(DiskUsage.make(from: .values(total: 100, available: 101, availableForImportantUsage: nil)), .unavailable(.inconsistentValues))
    }

    func testImportantUsageProblemsDoNotHideTheMainValues() throws {
        let missing = try usage(.values(total: 100, available: 40, availableForImportantUsage: nil))
        XCTAssertEqual(missing.availableForImportantUsageBytes, .unavailable(.unsupported))
        XCTAssertEqual(missing.usedBytes, 60)

        XCTAssertEqual(try usage(.values(total: 100, available: 40, availableForImportantUsage: 101)).availableForImportantUsageBytes,
                       .unavailable(.inconsistentValues))
        XCTAssertEqual(try usage(.values(total: 100, available: 40, availableForImportantUsage: -1)).availableForImportantUsageBytes,
                       .unavailable(.inconsistentValues))
    }

    func testMissingPathReportsAPOSIXReadFailure() {
        guard case .failed(let code) = DiskSampler.read(path: "/nonexistent-\(UUID().uuidString)") else {
            return XCTFail("Expected a read failure")
        }
        XCTAssertEqual(code, ENOENT)
    }

    func testLiveSystemVolumeMatchesStatfs() async throws {
        let value = await DiskSampler().sample()
        let disk = try XCTUnwrap(value.value, "System volume unavailable: \(value)")
        var fs = statfs()
        XCTAssertEqual(statfs("/", &fs), 0)
        XCTAssertEqual(disk.totalBytes, UInt64(fs.f_blocks) * UInt64(fs.f_bsize))
        // Free space moves while the system runs; allow 1 GB between the two reads.
        let statfsAvailable = Double(UInt64(fs.f_bavail) * UInt64(fs.f_bsize))
        XCTAssertEqual(Double(disk.availableBytes), statfsAvailable, accuracy: 1e9)
        XCTAssertTrue((0...1).contains(disk.usedFraction))
        print("DISK_LIVE total=\(disk.totalBytes) available=\(disk.availableBytes) important=\(disk.availableForImportantUsageBytes) used=\(String(format: "%.1f", disk.usedFraction * 100))%")
    }
}
