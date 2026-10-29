import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Tokenly

final class TokenlyTests: XCTestCase {
    @MainActor
    func testAdditionalProviderVisibilityPersists() throws {
        let suite = TestDefaults.suite("Providers")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestDefaults.discard(defaults, suite: suite) }
        let settings = ProviderDisplaySettings(defaults: defaults)
        XCTAssertFalse(settings.showsAGY)
        XCTAssertFalse(settings.showsOpenAIAPI)
        settings.showsCodex = false
        settings.showsAGY = true
        settings.showsOpenAIAPI = true
        let reloaded = ProviderDisplaySettings(defaults: defaults)
        XCTAssertEqual(reloaded.visibleSupportedProviders, ["Google Antigravity"])
        XCTAssertTrue(reloaded.showsOpenAIAPI) // Persisted preference is retained while integration is paused.
        reloaded.showsAGY = false
        reloaded.showsOpenAIAPI = false
        XCTAssertTrue(reloaded.visibleSupportedProviders.isEmpty)
    }

    @MainActor
    func testAccordionDefaultsPersistIndependentlyOfVisibility() throws {
        let suite = TestDefaults.suite("Accordion")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestDefaults.discard(defaults, suite: suite) }
        let settings = ProviderDisplaySettings(defaults: defaults)
        XCTAssertTrue(settings.codexExpanded)
        XCTAssertFalse(settings.agyExpanded)
        settings.codexExpanded = false
        settings.agyExpanded = true
        settings.showsCodex = false
        let reloaded = ProviderDisplaySettings(defaults: defaults)
        XCTAssertFalse(reloaded.codexExpanded)
        XCTAssertTrue(reloaded.agyExpanded)
        XCTAssertFalse(reloaded.showsCodex)
        XCTAssertFalse(reloaded.showsAGY)
        reloaded.showsAGY = true
        XCTAssertEqual(reloaded.visibleSupportedProviders, ["Google Antigravity"])
        reloaded.showsCodex = true
        XCTAssertEqual(reloaded.visibleSupportedProviders, ["Codex", "Google Antigravity"])
        XCTAssertFalse(reloaded.codexExpanded)
        XCTAssertTrue(reloaded.agyExpanded)
        reloaded.agyExpanded = false
        XCTAssertFalse(ProviderDisplaySettings(defaults: defaults).agyExpanded)
    }

    func testAGYSummaryShowsRangeInsteadOfMisleadingSingleBucket() {
        let quotas = [
            QuotaMetric(name: "3p-weekly", remainingPercent: 100, resetsAt: nil),
            QuotaMetric(name: "gemini-weekly", remainingPercent: 0, resetsAt: nil)
        ]
        XCTAssertEqual(AGYQuotaSummary.text(for: quotas), "2개 버킷 · 0–100%")
        XCTAssertTrue(AGYQuotaSummary.hasExhaustedBucket(quotas))
        XCTAssertEqual(AGYQuotaLabel.displayName(for: "3p-weekly"), "3p-weekly")
        XCTAssertEqual(AGYQuotaSummary.text(for: [quotas[1]]), "gemini-weekly 0%")
        XCTAssertEqual(AGYQuotaSummary.text(for: []), "쿼터 데이터 없음")
    }

    @MainActor
    func testCollapsedAGYStillRefreshesWhenVisible() async throws {
        let suite = TestDefaults.suite("CollapsedRefresh")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestDefaults.discard(defaults, suite: suite) }
        let settings = ProviderDisplaySettings(defaults: defaults)
        settings.showsAGY = true
        XCTAssertFalse(settings.agyExpanded)
        let provider = CountingExternalProvider()
        let store = ExternalProviderStore(displaySettings: settings, providers: [.antigravity: provider])
        store.refreshSelected()
        for _ in 0..<20 {
            if case .success = store.state(for: .antigravity) { break }
            await Task.yield()
        }
        let firstCount = await provider.fetchCount
        XCTAssertEqual(firstCount, 1)
        settings.showsAGY = false
        store.refreshSelected()
        let secondCount = await provider.fetchCount
        XCTAssertEqual(secondCount, 1)
    }

    func testAGYOfficialQuotaFieldsAndStaleState() throws {
        let now = Date(timeIntervalSince1970: 1_792_700_000)
        let stamp = ISO8601DateFormatter().string(from: now)
        let data = Data("""
        {"captured_at":"\(stamp)","quota":{"gemini-weekly":{"remaining_fraction":0.25,"reset_time":"2026-10-23T01:00:00Z"},"bad":{"remaining_fraction":1.4}},"email":"ignored@example.com"}
        """.utf8)
        let snapshot = try AGYQuotaParser.parse(data, now: now)
        guard case .quotas(let quotas) = snapshot.metrics else { return XCTFail("Expected quotas") }
        XCTAssertEqual(quotas.count, 1)
        XCTAssertEqual(quotas[0].remainingPercent, 25)
        XCTAssertNotNil(quotas[0].resetsAt)
        XCTAssertThrowsError(try AGYQuotaParser.parse(data, now: now.addingTimeInterval(901))) {
            XCTAssertEqual($0 as? ExternalProviderError, .staleData)
        }
    }

    func testAGYZeroQuotaIsValidButOldFeedIsStale() throws {
        let received = Date(timeIntervalSince1970: 1_792_700_000)
        let stamp = ISO8601DateFormatter().string(from: received)
        let data = Data("""
        {"captured_at":"\(stamp)","quota":{"gemini-weekly":{"remaining_fraction":0,"reset_time":null},"3p-weekly":{"remaining_fraction":1,"reset_time":null}}}
        """.utf8)
        let fresh = try AGYQuotaParser.parse(data, now: received.addingTimeInterval(899))
        guard case .quotas(let quotas) = fresh.metrics else { return XCTFail("Expected quotas") }
        XCTAssertEqual(quotas.map(\.remainingPercent).sorted(), [0, 100])
        XCTAssertThrowsError(try AGYQuotaParser.parse(data, now: received.addingTimeInterval(901))) {
            XCTAssertEqual($0 as? ExternalProviderError, .staleData)
        }
        XCTAssertTrue(ExternalProviderError.staleData.message.contains("15분"))
    }

    func testAGYRequiresConfiguredFeed() async {
        let provider = AGYStatusLineProvider(fileURL: URL(fileURLWithPath: "/nonexistent/tokenly/agy-quota.json"))
        do { _ = try await provider.fetch(); XCTFail("Expected setupRequired") }
        catch { XCTAssertEqual(error as? ExternalProviderError, .setupRequired) }
    }

    func testClaudeRequiresOfficialStatusLineFeed() async {
        let provider = ClaudeSubscriptionProvider(fileURL: URL(fileURLWithPath: "/nonexistent/tokenly/claude-quota.json"))
        do { _ = try await provider.fetch(); XCTFail("Expected setupRequired") }
        catch { XCTAssertEqual(error as? ExternalProviderError, .setupRequired) }
    }

    func testClaudeQuotaParserUsesOnlyValidIndependentWindows() throws {
        let now = Date(timeIntervalSince1970: 1_792_700_000)
        let captured = ISO8601DateFormatter().string(from: now)
        let data = Data("""
        {"captured_at":"\(captured)","rate_limits":{"five_hour":{"used_percentage":0,"resets_at":1792703600},"seven_day":{"used_percentage":100,"resets_at":1793300000},"spend_limit":{"used_percentage":12}},"email":"ignored@example.com"}
        """.utf8)
        let snapshot = try ClaudeQuotaParser.parse(data, now: now)
        guard case .quotas(let quotas) = snapshot.metrics else { return XCTFail("Expected quotas") }
        XCTAssertEqual(quotas.map(\.remainingPercent), [100, 0])
        XCTAssertEqual(quotas.map(\.name), ["5시간 한도", "7일 한도"])
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertNotNil(quotas[0].resetsAt)
    }

    func testClaudeMissingExpiredAndInvalidWindowsAreNotZero() throws {
        let now = Date(timeIntervalSince1970: 1_792_700_000)
        let captured = ISO8601DateFormatter().string(from: now)
        let partial = Data("""
        {"captured_at":"\(captured)","rate_limits":{"five_hour":{"used_percentage":35,"resets_at":1792703600},"seven_day":{"used_percentage":101,"resets_at":1793300000}}}
        """.utf8)
        let snapshot = try ClaudeQuotaParser.parse(partial, now: now)
        guard case .quotas(let quotas) = snapshot.metrics else { return XCTFail("Expected quotas") }
        XCTAssertEqual(quotas.count, 1)
        XCTAssertEqual(quotas[0].remainingPercent, 65)
        let expired = Data("""
        {"captured_at":"\(captured)","rate_limits":{"five_hour":{"used_percentage":35,"resets_at":1792690000}}}
        """.utf8)
        XCTAssertThrowsError(try ClaudeQuotaParser.parse(expired, now: now)) {
            XCTAssertEqual($0 as? ExternalProviderError, .noData)
        }
        let absent = Data("{\"captured_at\":\"\(captured)\",\"rate_limits\":{}}".utf8)
        XCTAssertThrowsError(try ClaudeQuotaParser.parse(absent, now: now)) {
            XCTAssertEqual($0 as? ExternalProviderError, .noData)
        }
    }

    func testClaudeStaleThenFreshReceipt() throws {
        let now = Date(timeIntervalSince1970: 1_792_700_000)
        func receipt(_ date: Date) -> Data {
            let stamp = ISO8601DateFormatter().string(from: date)
            return Data("{\"captured_at\":\"\(stamp)\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":20,\"resets_at\":1792703600}}}".utf8)
        }
        XCTAssertThrowsError(try ClaudeQuotaParser.parse(receipt(now), now: now.addingTimeInterval(901))) {
            XCTAssertEqual($0 as? ExternalProviderError, .claudeStaleData)
        }
        XCTAssertEqual(try ClaudeQuotaParser.parse(receipt(now.addingTimeInterval(901)),
                                                     now: now.addingTimeInterval(901)).fetchedAt,
                       now.addingTimeInterval(901))
    }

    @MainActor
    func testClaudeVisibilityAndAccordionPersist() throws {
        let suite = TestDefaults.suite("Claude")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestDefaults.discard(defaults, suite: suite) }
        let settings = ProviderDisplaySettings(defaults: defaults)
        XCTAssertFalse(settings.showsClaude)
        XCTAssertFalse(settings.claudeExpanded)
        settings.showsClaude = true
        settings.claudeExpanded = true
        let reloaded = ProviderDisplaySettings(defaults: defaults)
        XCTAssertTrue(reloaded.showsClaude)
        XCTAssertTrue(reloaded.claudeExpanded)
        XCTAssertEqual(reloaded.visibleSupportedProviders, ["Codex", "Claude"])
    }

    @MainActor
    func testPopoverProviderOrderIsCodexClaudeAGY() throws {
        let suite = TestDefaults.suite("Order")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestDefaults.discard(defaults, suite: suite) }
        let settings = ProviderDisplaySettings(defaults: defaults)
        settings.showsCodex = true
        settings.showsAGY = true
        settings.showsClaude = true
        XCTAssertEqual(ProviderDisplaySettings(defaults: defaults).visibleSupportedProviders,
                       ["Codex", "Claude", "Google Antigravity"])
    }

    func testOpenAIReportsTokenAndCostTotalsWithoutModelCall() async throws {
        let now = Date(timeIntervalSince1970: 1_792_700_000)
        var paths: [String] = []
        let provider = OpenAIAPIUsageProvider(keys: StubAdminKeyStore(key: "sk-admin-test-key"), now: { now }) { request in
            paths.append(request.url!.path)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(request.url!.path.hasPrefix("/v1/organization/"))
            let body: String = request.url!.path.hasSuffix("/costs")
                ? #"{"data":[{"results":[{"amount":{"value":1.25,"currency":"usd"}}]}],"has_more":false,"next_page":null}"#
                : #"{"data":[{"results":[{"input_tokens":120,"output_tokens":30}]}],"has_more":false,"next_page":null}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let value = try await provider.fetch()
        guard case .api(let day, let month) = value.metrics else { return XCTFail("Expected API totals") }
        XCTAssertEqual(day, APITotals(inputTokens: 120, outputTokens: 30, costUSD: 1.25))
        XCTAssertEqual(month, day)
        XCTAssertEqual(paths.count, 4)
    }

    func testOpenAIMissingAdminKeyAndPermissionError() async {
        let missing = OpenAIAPIUsageProvider(keys: StubAdminKeyStore(key: nil), request: { _ in XCTFail("No request without key"); throw ExternalProviderError.connection })
        do { _ = try await missing.fetch(); XCTFail("Expected authenticationRequired") }
        catch { XCTAssertEqual(error as? ExternalProviderError, .authenticationRequired) }

        let regularKey = OpenAIAPIUsageProvider(keys: StubAdminKeyStore(key: "sk-regular-key"), request: { _ in
            XCTFail("A regular key must not call admin endpoints")
            throw ExternalProviderError.connection
        })
        do { _ = try await regularKey.fetch(); XCTFail("Expected permissionDenied") }
        catch { XCTAssertEqual(error as? ExternalProviderError, .permissionDenied) }

        let denied = OpenAIAPIUsageProvider(keys: StubAdminKeyStore(key: "sk-admin-test-key"), request: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        })
        do { _ = try await denied.fetch(); XCTFail("Expected permissionDenied") }
        catch { XCTAssertEqual(error as? ExternalProviderError, .permissionDenied) }
    }

    func testOpenAITimeoutDoesNotExposeCredential() async {
        let provider = OpenAIAPIUsageProvider(keys: StubAdminKeyStore(key: "sk-admin-secret-test-key"), request: { _ in
            throw URLError(.timedOut)
        })
        do { _ = try await provider.fetch(); XCTFail("Expected timeout") }
        catch {
            XCTAssertEqual(error as? ExternalProviderError, .timeout)
            XCTAssertFalse(String(describing: error).contains("sk-admin-secret-test-key"))
        }
    }

    @MainActor
    func testProviderVisibilityPersistsAndDefaultsToShown() throws {
        let suite = TestDefaults.suite("ProviderVisibility")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestDefaults.discard(defaults, suite: suite) }
        let initial = ProviderDisplaySettings(defaults: defaults)
        XCTAssertTrue(initial.showsCodex)
        XCTAssertEqual(initial.visibleSupportedProviders, ["Codex"])
        initial.showsCodex = false
        let reloaded = ProviderDisplaySettings(defaults: defaults)
        XCTAssertFalse(reloaded.showsCodex)
        XCTAssertTrue(reloaded.visibleSupportedProviders.isEmpty)
        reloaded.showsCodex = true
        XCTAssertEqual(ProviderDisplaySettings(defaults: defaults).visibleSupportedProviders, ["Codex"])
    }

    @MainActor
    func testSettingsWindowReusesVisibleWindow() {
        let manager = SettingsWindowManager()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        manager.window = window
        window.orderFront(nil)
        var opens = 0
        manager.show { opens += 1 }
        XCTAssertEqual(opens, 0)
        window.orderOut(nil)
        manager.show { opens += 1 }
        XCTAssertEqual(opens, 1)
    }

    func testTwoWindowsFromCodexBucket() throws {
        let data = Data("""
        {"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1792700000},"secondary":{"usedPercent":63,"windowDurationMins":10080,"resetsAt":1793100000}}}}}
        """.utf8)
        let snapshot = try CodexRateLimitParser.parse(data)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.window(.fiveHours)?.remainingPercent, 88)
        XCTAssertEqual(snapshot.window(.sevenDays)?.remainingPercent, 37)
        XCTAssertNotNil(snapshot.window(.fiveHours)?.resetsAt)
    }

    func testPartialAndInvalidWindows() throws {
        let data = Data("""
        {"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":101,"windowDurationMins":300,"resetsAt":null},"secondary":{"usedPercent":42.5,"windowDurationMins":10080,"resetsAt":null}}}}
        """.utf8)
        let snapshot = try CodexRateLimitParser.parse(data)
        XCTAssertNil(snapshot.window(.fiveHours))
        XCTAssertEqual(snapshot.window(.sevenDays)?.remainingPercent, 57.5)
        XCTAssertNil(snapshot.window(.sevenDays)?.resetsAt)
    }

    func testDefaultBucketWithoutLimitId() throws {
        let data = Data(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":null}}}}"#.utf8)
        let snapshot = try CodexRateLimitParser.parse(data)
        XCTAssertEqual(snapshot.window(.fiveHours)?.remainingPercent, 75)
    }

    func testEmptyAndMalformedResponses() throws {
        let empty = Data(#"{"id":2,"result":{"rateLimits":null}}"#.utf8)
        XCTAssertTrue(try CodexRateLimitParser.parse(empty).windows.isEmpty)
        XCTAssertThrowsError(try CodexRateLimitParser.parse(Data("not-json".utf8))) {
            XCTAssertEqual($0 as? UsageProviderError, .invalidResponse)
        }
    }

    func testReadErrorIsNotDataAbsence() {
        let data = Data(#"{"id":2,"error":{"code":-32000,"message":"private detail"}}"#.utf8)
        XCTAssertThrowsError(try CodexRateLimitParser.parse(data)) {
            XCTAssertEqual($0 as? UsageProviderError, .requestFailed)
        }
    }

    func testMissingCLIIsHandled() async {
        let provider = CodexUsageProvider(executableURL: URL(fileURLWithPath: "/nonexistent/tokenly/codex"))
        do {
            _ = try await provider.fetch()
            XCTFail("Expected missing executable")
        } catch {
            XCTAssertEqual(error as? UsageProviderError, .cliUnavailable)
        }
    }

    func testCLIResolutionUsesPath() {
        let url = CodexUsageProvider.findCLI(environment: ["PATH": "/example/bin"],
                                            isExecutable: { $0 == "/example/bin/codex" })
        XCTAssertEqual(url?.path, "/example/bin/codex")
        let missing = CodexUsageProvider.findCLI(environment: ["PATH": ""], isExecutable: { _ in false })
        XCTAssertNil(missing)
    }

    func testCLIResolutionWithoutFinderPathUsesKnownLocations() {
        let home = "/Users/example"
        let url = CodexUsageProvider.findCLI(environment: ["PATH": "/usr/bin", "HOME": home],
                                            isExecutable: { $0 == "/opt/homebrew/bin/codex" })
        XCTAssertEqual(url?.path, "/opt/homebrew/bin/codex")
        let local = CodexUsageProvider.findCLI(environment: ["PATH": "", "HOME": home],
                                              isExecutable: { $0 == home + "/.local/bin/codex" })
        XCTAssertEqual(local?.path, home + "/.local/bin/codex")
    }

    @MainActor
    func testLoginItemExplicitEnableDisableAndFailure() {
        let fake = FakeLoginItemController()
        let manager = LoginItemManager(controller: fake, bundleURL: URL(fileURLWithPath: "/Applications/Tokenly.app"))
        XCTAssertEqual(manager.state, .off)
        XCTAssertEqual(fake.registerCalls, 0)
        manager.setEnabled(true)
        XCTAssertEqual(fake.registerCalls, 1)
        XCTAssertEqual(manager.state, .on)
        manager.setEnabled(false)
        XCTAssertEqual(fake.unregisterCalls, 1)
        XCTAssertEqual(manager.state, .off)
        fake.fail = true
        manager.setEnabled(true)
        XCTAssertEqual(manager.state, .off)
        XCTAssertNotNil(manager.errorMessage)
    }

    @MainActor
    func testLoginItemCannotRegisterFromDevelopmentBuild() {
        let fake = FakeLoginItemController()
        let manager = LoginItemManager(controller: fake, bundleURL: URL(fileURLWithPath: "/private/tmp/Tokenly.app"))
        manager.setEnabled(true)
        XCTAssertEqual(fake.registerCalls, 0)
        XCTAssertFalse(manager.isInstalled)
        XCTAssertNotNil(manager.errorMessage)
    }

    @MainActor
    func testLoginItemNotFoundOnInstalledAppAllowsRegisterAttempt() {
        let fake = FakeLoginItemController()
        fake.state = .unavailable                      // SMAppService.mainApp.status == .notFound
        let manager = LoginItemManager(controller: fake, bundleURL: URL(fileURLWithPath: "/Applications/Tokenly.app"))
        XCTAssertEqual(manager.state, .unavailable)    // not silently treated as .off
        XCTAssertTrue(manager.canChange)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertTrue(manager.statusMessage.contains("켜면 등록을 시도합니다"))
        manager.setEnabled(true)
        XCTAssertEqual(fake.registerCalls, 1)
        XCTAssertEqual(manager.state, .on)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.statusMessage, "켜짐 · 다음 로그인부터 실행됩니다.")
    }

    @MainActor
    func testLoginItemNotFoundRegisterFailureKeepsToggleOffAndShowsError() {
        let fake = FakeLoginItemController()
        fake.state = .unavailable
        fake.fail = true
        let manager = LoginItemManager(controller: fake, bundleURL: URL(fileURLWithPath: "/Applications/Tokenly.app"))
        manager.setEnabled(true)
        XCTAssertEqual(fake.registerCalls, 1)
        XCTAssertEqual(manager.state, .unavailable)
        XCTAssertFalse(manager.isEnabled)              // the toggle reads isEnabled, so it snaps back to off
        let message = try? XCTUnwrap(manager.errorMessage)
        XCTAssertTrue(message?.contains("등록에 실패했습니다") == true)
        XCTAssertTrue(message?.contains("fake register error") == true)
        XCTAssertEqual(manager.statusMessage, message)
    }

    @MainActor
    func testLoginItemRegisterWithoutErrorButNotConfirmedIsNotShownAsOn() {
        let fake = FakeLoginItemController()
        fake.state = .unavailable
        fake.stateAfterRegister = .unavailable         // call returned, status still .notFound
        let manager = LoginItemManager(controller: fake, bundleURL: URL(fileURLWithPath: "/Applications/Tokenly.app"))
        manager.setEnabled(true)
        XCTAssertEqual(fake.registerCalls, 1)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertTrue(manager.errorMessage?.contains("켜짐 상태가 확인되지 않았습니다") == true)
        XCTAssertFalse(manager.statusMessage.hasPrefix("켜짐"))
    }

    @MainActor
    func testLoginItemRequiresApprovalAfterRegister() {
        let fake = FakeLoginItemController()
        fake.state = .unavailable
        fake.stateAfterRegister = .requiresApproval
        let manager = LoginItemManager(controller: fake, bundleURL: URL(fileURLWithPath: "/Applications/Tokenly.app"))
        manager.setEnabled(true)
        XCTAssertEqual(manager.state, .requiresApproval)
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.statusMessage, "시스템 설정의 로그인 항목에서 승인이 필요합니다.")
    }

    @MainActor
    func testLoginItemUnregisterFailureKeepsOnAndShowsError() {
        let fake = FakeLoginItemController()
        fake.state = .on
        fake.failUnregister = true
        let manager = LoginItemManager(controller: fake, bundleURL: URL(fileURLWithPath: "/Applications/Tokenly.app"))
        manager.setEnabled(false)
        XCTAssertEqual(fake.unregisterCalls, 1)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertTrue(manager.errorMessage?.contains("해제에 실패했습니다") == true)
    }

    @MainActor
    func testLoginItemNotFoundStillBlockedOutsideApplications() {
        let fake = FakeLoginItemController()
        fake.state = .unavailable
        for path in ["/private/tmp/Tokenly.app", NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData/X/Build/Products/Debug/Tokenly.app"] {
            let manager = LoginItemManager(controller: fake, bundleURL: URL(fileURLWithPath: path))
            XCTAssertFalse(manager.canChange, path)
            manager.setEnabled(true)
            XCTAssertNotNil(manager.errorMessage, path)
        }
        XCTAssertEqual(fake.registerCalls, 0)
    }

    func testRemainingLevelsAtBoundaries() {
        XCTAssertEqual(RemainingLevel(percent: 50.1), .healthy)
        XCTAssertEqual(RemainingLevel(percent: 50), .caution)
        XCTAssertEqual(RemainingLevel(percent: 20.1), .caution)
        XCTAssertEqual(RemainingLevel(percent: 20), .low)
    }

    func testMenuBarSummaryUsesRemainingPercentAndMissingMarker() {
        let snapshot = UsageSnapshot(providerName: "Codex", windows: [
            UsageWindow(kind: .fiveHours, usedPercent: 71, resetsAt: nil)
        ], fetchedAt: Date())
        XCTAssertEqual(snapshot.menuBarSummary, "5h 29% · 7d —")
        XCTAssertNil(UsageSnapshot(providerName: "Codex", windows: [], fetchedAt: Date()).menuBarSummary)
    }

    func testMenuBarStylesAndFailureStates() {
        let snapshot = UsageSnapshot(providerName: "Codex", windows: [
            UsageWindow(kind: .fiveHours, usedPercent: 0, resetsAt: nil),
            UsageWindow(kind: .sevenDays, usedPercent: 100, resetsAt: nil)
        ], fetchedAt: Date())
        XCTAssertEqual(MenuBarPresentation.text(style: .numeric, snapshot: snapshot, isRefreshing: false, hasError: false), "5h 100% · 7d 0%")
        XCTAssertEqual(MenuBarPresentation.text(style: .compact, snapshot: snapshot, isRefreshing: false, hasError: false), "100% · 0%")
        XCTAssertEqual(MenuBarPresentation.text(style: .compact, snapshot: snapshot, isRefreshing: false, hasError: true), "이전 · 100% · 0%")
        XCTAssertEqual(MenuBarPresentation.text(style: .numeric, snapshot: nil, isRefreshing: true, hasError: false), "조회 중")
        XCTAssertEqual(MenuBarPresentation.text(style: .numeric, snapshot: nil, isRefreshing: false, hasError: true), "조회 실패")
        let partial = UsageSnapshot(providerName: "Codex", windows: [
            UsageWindow(kind: .sevenDays, usedPercent: 3, resetsAt: nil)
        ], fetchedAt: Date())
        XCTAssertEqual(MenuBarPresentation.text(style: .numeric, snapshot: partial, isRefreshing: false, hasError: false), "5h — · 7d 97%")
        XCTAssertEqual(MenuBarPresentation.text(style: .compact, snapshot: partial, isRefreshing: false, hasError: false), "— · 97%")
    }

    @MainActor
    func testDisplayStyleAndAppearancePersist() throws {
        let suite = TestDefaults.suite("DisplayPreferences")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestDefaults.discard(defaults, suite: suite) }
        let settings = ProviderDisplaySettings(defaults: defaults)
        XCTAssertEqual(settings.menuBarStyle, .numeric)
        XCTAssertEqual(settings.appearance, .system)
        settings.menuBarStyle = .compact
        settings.appearance = .dark
        let reloaded = ProviderDisplaySettings(defaults: defaults)
        XCTAssertEqual(reloaded.menuBarStyle, .compact)
        XCTAssertEqual(reloaded.appearance, .dark)
        XCTAssertEqual(reloaded.appearance.colorScheme, .dark)
    }

    func testHeartRepresentativePercentUsesLowestValidValueClamped() {
        XCTAssertEqual(HeartGauge.representativePercent([82, 35, 61]), 35)
        XCTAssertEqual(HeartGauge.representativePercent([120, .nan, 90]), 90)
        XCTAssertEqual(HeartGauge.representativePercent([-5, 40]), 0)
        XCTAssertEqual(HeartGauge.representativePercent([100]), 100)
        XCTAssertNil(HeartGauge.representativePercent([]))
        XCTAssertNil(HeartGauge.representativePercent([.nan, .infinity]))
    }

    func testCodexHeartReadingFreshStaleAndHidden() {
        let snapshot = UsageSnapshot(providerName: "Codex", windows: [
            UsageWindow(kind: .fiveHours, usedPercent: 18, resetsAt: nil),
            UsageWindow(kind: .sevenDays, usedPercent: 40, resetsAt: nil)
        ], fetchedAt: Date())
        XCTAssertEqual(HeartGauge.codexReading(snapshot: snapshot, hasError: false), .fresh(60))
        XCTAssertEqual(HeartGauge.codexReading(snapshot: snapshot, hasError: true), .stale(60))
        XCTAssertNil(HeartGauge.codexReading(snapshot: nil, hasError: false))
        XCTAssertNil(HeartGauge.codexReading(snapshot: nil, hasError: true))
        XCTAssertNil(HeartGauge.codexReading(snapshot: UsageSnapshot(providerName: "Codex", windows: [], fetchedAt: Date()),
                                             hasError: false))
        let exhausted = UsageSnapshot(providerName: "Codex", windows: [
            UsageWindow(kind: .fiveHours, usedPercent: 100, resetsAt: nil)
        ], fetchedAt: Date())
        XCTAssertEqual(HeartGauge.codexReading(snapshot: exhausted, hasError: false), .fresh(0))
    }

    func testExternalHeartReadingHidesUnconnectedAndKeepsStaleHistory() {
        let quotas = [QuotaMetric(name: "3p-weekly", remainingPercent: 100, resetsAt: nil),
                      QuotaMetric(name: "gemini-weekly", remainingPercent: 0, resetsAt: nil)]
        let snapshot = ExternalUsageSnapshot(metrics: .quotas(quotas), fetchedAt: Date())
        XCTAssertEqual(HeartGauge.externalReading(.success(snapshot), lastValidQuotas: quotas), .fresh(0))
        let full = ExternalUsageSnapshot(metrics: .quotas([QuotaMetric(name: "5시간 한도", remainingPercent: 100, resetsAt: nil)]),
                                         fetchedAt: Date())
        XCTAssertEqual(HeartGauge.externalReading(.success(full), lastValidQuotas: nil), .fresh(100))
        // A stale status-line feed with earlier valid data stays visible as grey, not disconnected.
        let history = [QuotaMetric(name: "gemini-weekly", remainingPercent: 42, resetsAt: nil)]
        XCTAssertEqual(HeartGauge.externalReading(.failure(.staleData, previous: nil), lastValidQuotas: history), .stale(42))
        XCTAssertEqual(HeartGauge.externalReading(.failure(.claudeStaleData, previous: nil), lastValidQuotas: history), .stale(42))
        XCTAssertEqual(HeartGauge.externalReading(.failure(.connection, previous: snapshot), lastValidQuotas: quotas), .stale(0))
        // Never received, not connected, or not yet read: hidden.
        XCTAssertNil(HeartGauge.externalReading(.failure(.staleData, previous: nil), lastValidQuotas: nil))
        XCTAssertNil(HeartGauge.externalReading(.failure(.noData, previous: nil), lastValidQuotas: nil))
        XCTAssertNil(HeartGauge.externalReading(.failure(.setupRequired, previous: snapshot), lastValidQuotas: history))
        XCTAssertNil(HeartGauge.externalReading(.idle, lastValidQuotas: history))
        let api = ExternalUsageSnapshot(metrics: .api(day: APITotals(inputTokens: 1, outputTokens: 1, costUSD: 0),
                                                      month: APITotals(inputTokens: 1, outputTokens: 1, costUSD: 0)),
                                        fetchedAt: Date())
        XCTAssertNil(HeartGauge.externalReading(.success(api), lastValidQuotas: nil))
        XCTAssertEqual(HeartGaugeReading.fresh(81.6).percentText, "82%")
        XCTAssertEqual(HeartGaugeReading.stale(0).percentText, "0%")
    }

    func testStoredQuotaRecordIgnoresAgeButRequiresValidValues() throws {
        let old = "2020-01-01T00:00:00Z"
        let agy = Data(#"{"captured_at":"\#(old)","quota":{"gemini-weekly":{"remaining_fraction":0.25},"bad":{"remaining_fraction":3}}}"#.utf8)
        XCTAssertEqual(AGYQuotaParser.storedRecord(agy)?.map(\.remainingPercent), [25])
        XCTAssertThrowsError(try AGYQuotaParser.parse(agy, now: Date()))
        XCTAssertNil(AGYQuotaParser.storedRecord(Data(#"{"captured_at":"\#(old)","quota":{}}"#.utf8)))
        XCTAssertNil(AGYQuotaParser.storedRecord(Data("not json".utf8)))
        let claude = Data(#"{"captured_at":"\#(old)","rate_limits":{"five_hour":{"used_percentage":70,"resets_at":1}}}"#.utf8)
        XCTAssertEqual(ClaudeQuotaParser.storedRecord(claude)?.map(\.remainingPercent), [30])
        XCTAssertNil(ClaudeQuotaParser.storedRecord(Data(#"{"captured_at":"\#(old)","rate_limits":{}}"#.utf8)))
    }

    @MainActor
    func testStaleFeedWithStoredRecordShowsGreyHeartAndMissingFeedHides() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let feed = folder.appendingPathComponent("agy-quota.json")
        try Data(#"{"captured_at":"2020-01-01T00:00:00Z","quota":{"gemini-weekly":{"remaining_fraction":0.4}}}"#.utf8).write(to: feed)
        let suite = TestDefaults.suite("HeartStore")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestDefaults.discard(defaults, suite: suite) }
        let settings = ProviderDisplaySettings(defaults: defaults)
        settings.showsAGY = true
        let store = ExternalProviderStore(displaySettings: settings,
                                          providers: [.antigravity: AGYStatusLineProvider(fileURL: feed)])
        await store.refresh(.antigravity)?.value
        XCTAssertEqual(HeartGauge.externalReading(store.settledState(for: .antigravity),
                                                  lastValidQuotas: store.lastValidQuotas[.antigravity]), .stale(40))
        let missing = ExternalProviderStore(displaySettings: settings, providers: [
            .antigravity: AGYStatusLineProvider(fileURL: folder.appendingPathComponent("none.json"))])
        await missing.refresh(.antigravity)?.value
        XCTAssertNil(HeartGauge.externalReading(missing.settledState(for: .antigravity),
                                                lastValidQuotas: missing.lastValidQuotas[.antigravity]))
    }

    @MainActor
    func testStylesPersistSwitchAndGaugesFollowVisibilityOrder() throws {
        let suite = TestDefaults.suite("Styles")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestDefaults.discard(defaults, suite: suite) }
        let settings = ProviderDisplaySettings(defaults: defaults)
        XCTAssertEqual(settings.menuBarStyle, .numeric)
        for style in [MenuBarDisplayStyle.compact, .numeric] {
            settings.menuBarStyle = style
            XCTAssertEqual(ProviderDisplaySettings(defaults: defaults).menuBarStyle, style)
        }
        let reloaded = ProviderDisplaySettings(defaults: defaults)
        XCTAssertEqual(HeartGauge.visibleProviders(reloaded), [.codex])
        reloaded.showsAGY = true
        reloaded.showsClaude = true
        XCTAssertEqual(HeartGauge.visibleProviders(reloaded), [.codex, .claude, .antigravity])
        reloaded.showsCodex = false
        XCTAssertEqual(HeartGauge.visibleProviders(reloaded), [.claude, .antigravity])
    }

    @MainActor
    func testSupportedStylesAndRemovedStylesMigrateToNumeric() throws {
        XCTAssertEqual(MenuBarDisplayStyle.allCases, [.numeric, .compact])
        for removed in ["icon", "heart", "bear"] {
            let suite = TestDefaults.suite("Migration.\(removed)")
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { TestDefaults.discard(defaults, suite: suite) }
            defaults.set(removed, forKey: ProviderDisplaySettings.menuBarStyleKey)
            defaults.set(AppAppearance.dark.rawValue, forKey: ProviderDisplaySettings.appearanceKey)
            defaults.set(true, forKey: ProviderDisplaySettings.claudeVisibilityKey)
            defaults.set(false, forKey: ProviderDisplaySettings.codexExpandedKey)
            let settings = ProviderDisplaySettings(defaults: defaults)
            XCTAssertEqual(settings.menuBarStyle, .numeric, "\(removed) → numeric")
            // Written back once; every other saved setting is preserved.
            XCTAssertEqual(defaults.string(forKey: ProviderDisplaySettings.menuBarStyleKey), "numeric")
            XCTAssertEqual(settings.appearance, .dark)
            XCTAssertTrue(settings.showsClaude)
            XCTAssertFalse(settings.codexExpanded)
        }
        // Existing valid choices are kept as they are.
        let suite = TestDefaults.suite("Migration.keep")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestDefaults.discard(defaults, suite: suite) }
        defaults.set(MenuBarDisplayStyle.compact.rawValue, forKey: ProviderDisplaySettings.menuBarStyleKey)
        XCTAssertEqual(ProviderDisplaySettings(defaults: defaults).menuBarStyle, .compact)
        XCTAssertEqual(defaults.string(forKey: ProviderDisplaySettings.menuBarStyleKey), "compact")
    }

    @MainActor
    // MARK: Numeric style (5h large/high, 7d 20% smaller/lower, name below)

    func testNumericItemsMapFiveHourAndSevenDayWithHeartVisibilityRules() {
        let codex = UsageSnapshot(providerName: "Codex", windows: [
            UsageWindow(kind: .fiveHours, usedPercent: 60, resetsAt: nil),
            UsageWindow(kind: .sevenDays, usedPercent: 30, resetsAt: nil)
        ], fetchedAt: Date())
        XCTAssertEqual(NumericGauge.codexItem(snapshot: codex, hasError: false),
                       NumericGaugeItem(provider: .codex, primary: 40, secondary: 70, hasSecondarySlot: true, stale: false))
        XCTAssertEqual(NumericGauge.codexItem(snapshot: codex, hasError: true)?.stale, true)
        XCTAssertNil(NumericGauge.codexItem(snapshot: nil, hasError: false))
        let fiveOnly = UsageSnapshot(providerName: "Codex", windows: [UsageWindow(kind: .fiveHours, usedPercent: 91, resetsAt: nil)],
                                     fetchedAt: Date())
        XCTAssertEqual(NumericGaugeItem.text(NumericGauge.codexItem(snapshot: fiveOnly, hasError: false)?.secondary), "—")

        let claudeQuotas = [QuotaMetric(name: NumericGauge.claudeFiveHour, remainingPercent: 100, resetsAt: nil),
                            QuotaMetric(name: NumericGauge.claudeSevenDay, remainingPercent: 9, resetsAt: nil)]
        let claude = NumericGauge.externalItem(.claude, settled: .success(ExternalUsageSnapshot(metrics: .quotas(claudeQuotas), fetchedAt: Date())),
                                               lastValidQuotas: claudeQuotas)
        XCTAssertEqual(claude, NumericGaugeItem(provider: .claude, primary: 100, secondary: 9, hasSecondarySlot: true, stale: false))
        let staleClaude = NumericGauge.externalItem(.claude, settled: .failure(.claudeStaleData, previous: nil), lastValidQuotas: claudeQuotas)
        XCTAssertEqual(staleClaude?.stale, true)
        XCTAssertEqual(staleClaude?.primary, 100)
        XCTAssertNil(NumericGauge.externalItem(.claude, settled: .failure(.setupRequired, previous: nil), lastValidQuotas: claudeQuotas))
        XCTAssertNil(NumericGauge.externalItem(.antigravity, settled: .idle, lastValidQuotas: nil))

        // AGY buckets are not 5h/7d windows: only the lowest bucket, no second slot.
        let buckets = [QuotaMetric(name: "3p-weekly", remainingPercent: 80, resetsAt: nil),
                       QuotaMetric(name: "gemini-weekly", remainingPercent: 54, resetsAt: nil)]
        let agy = NumericGauge.externalItem(.antigravity, settled: .success(ExternalUsageSnapshot(metrics: .quotas(buckets), fetchedAt: Date())),
                                            lastValidQuotas: buckets)
        XCTAssertEqual(agy, NumericGaugeItem(provider: .antigravity, primary: 54, secondary: nil, hasSecondarySlot: false, stale: false))
        XCTAssertEqual(NumericGaugeItem.text(100), "100")
        XCTAssertEqual(NumericGaugeItem.text(0), "0")
        XCTAssertEqual(NumericGaugeItem.text(nil), "—")
    }

    /// 7d is 20% smaller and 2pt lower than 5h with ≥1pt clear around "/"; lighter weights (5h Semibold,
    /// 7d Medium); every column shares the name baseline; digits never touch the name and nothing
    /// touches the bitmap edge, for 97/89, 28/91, 100/100, 9/100 and 0/0.
    func testNumericLayoutHierarchyAlignmentAndNoOverlap() throws {
        let layout = MenuBarNumericImage.Layout.standard
        XCTAssertEqual(layout.secondaryRatio, 0.8, accuracy: 0.001)
        XCTAssertEqual(layout.drop, 2.0, accuracy: 0.001)
        XCTAssertEqual(layout.separatorGap, 1.2, accuracy: 0.001)
        XCTAssertEqual(layout.columnSpacing, 16, accuracy: 0.001)
        XCTAssertEqual(layout.primaryWeight, .semibold)
        XCTAssertEqual(layout.secondaryWeight, .medium)
        XCTAssertEqual(layout.nameWeight, .semibold)
        func item(_ p: HeartGaugeProvider, _ a: Double?, _ b: Double?) -> NumericGaugeItem {
            NumericGaugeItem(provider: p, primary: a, secondary: b, hasSecondarySlot: p != .antigravity, stale: false)
        }
        let rows = [[item(.codex, 97, 89), item(.claude, 28, 91), item(.antigravity, 9, nil)],
                    [item(.codex, 100, 100), item(.claude, 9, 100), item(.antigravity, 100, nil)],
                    [item(.codex, 0, 0), item(.claude, 40, 70)]]
        for items in rows {
            var nameBaselines: Set<CGFloat> = []
            for it in items {
                let column = MenuBarNumericImage.column(it, layout: layout, color: .black)
                let digits = column.runs.dropLast(), name = try XCTUnwrap(column.runs.last)
                nameBaselines.insert(name.baseline)
                let lowestDigit = digits.map { $0.baseline - MenuBarNumericImage.ink($0.line).minY }.max() ?? 0
                let nameTop = name.baseline - MenuBarNumericImage.ink(name.line).maxY
                let nameBottom = name.baseline - MenuBarNumericImage.ink(name.line).minY
                let topDigit = digits.map { $0.baseline - MenuBarNumericImage.ink($0.line).maxY }.min() ?? 0
                XCTAssertGreaterThanOrEqual(nameTop - lowestDigit, 1.5, "\(it.name) digits too close to the name")
                XCTAssertGreaterThan(topDigit, 1, "\(it.name) top clipped")
                XCTAssertLessThan(nameBottom, 21, "\(it.name) bottom clipped")
                if it.hasSecondarySlot {
                    let primary = try XCTUnwrap(digits.first), secondary = try XCTUnwrap(digits.last)
                    XCTAssertEqual(secondary.baseline - primary.baseline, 2.0, accuracy: 0.01)
                    // Visual space between 5h ink, "/" ink and 7d ink, from actual glyph positions.
                    let boxes = digits.map { r -> CGRect in
                        let i = MenuBarNumericImage.ink(r.line)
                        return CGRect(x: r.x + i.minX, y: r.baseline - i.maxY, width: i.width, height: i.height)
                    }
                    for (left, right) in zip(boxes, boxes.dropFirst()) {
                        XCTAssertEqual(right.minX - left.maxX, 1.2, accuracy: 0.01, "\(it.name) gap around the slash")
                    }
                    let pSize = CTFontGetSize(try XCTUnwrap(fontOf(primary.line)))
                    let sSize = CTFontGetSize(try XCTUnwrap(fontOf(secondary.line)))
                    XCTAssertEqual(sSize / pSize, 0.8, accuracy: 0.01)
                }
            }
            XCTAssertEqual(nameBaselines.count, 1, "names must share one baseline across columns")
            for dark in [false, true] {
                let image = try XCTUnwrap(MenuBarNumericImage.render(items, dark: dark, scale: 2))
                XCTAssertEqual(image.height, 44)
                let px = rgba(image), w = image.width, h = image.height
                func a(_ x: Int, _ y: Int) -> UInt8 { px[(y * w + x) * 4 + 3] }
                XCTAssertEqual((0..<w).map { max(a($0, 0), a($0, h - 1)) }.max(), 0)
                XCTAssertEqual((0..<h).map { max(a(0, $0), a(w - 1, $0)) }.max(), 0)
            }
            XCTAssertEqual(MenuBarNumericImage.size(items).height, 22)
        }
    }

    private func fontOf(_ line: CTLine) -> CTFont? {
        guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first else { return nil }
        let attributes = CTRunGetAttributes(run) as NSDictionary
        return attributes[kCTFontAttributeName as String].map { $0 as! CTFont }
    }

    // MARK: Codex rate-limit reset credits (official account/rateLimits/read, read-only)

    private func codexResponse(_ resetCredits: String) -> Data {
        Data("""
        {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":30,"windowDurationMins":300,"resetsAt":1792710000},
        "secondary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":1793000000}}\(resetCredits)}}
        """.utf8)
    }

    func testResetCreditsParseCountAndExpiries() throws {
        let now = Date(timeIntervalSince1970: 1_792_700_000)
        let data = codexResponse(#","rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"a","grantedAt":1792000000,"expiresAt":1793900000,"status":"available","resetType":"codexRateLimits","title":"T"},{"id":"b","grantedAt":1792000000,"expiresAt":1793270000,"status":"available","resetType":"codexRateLimits","title":null}]}"#)
        let snapshot = try CodexRateLimitParser.parse(data, fetchedAt: now)
        XCTAssertEqual(snapshot.windows.count, 2)
        let credits = try XCTUnwrap(snapshot.resetCredits)
        XCTAssertEqual(credits.availableCount, 2)
        XCTAssertEqual(credits.usableCount(now: now), 2)
        // Soonest expiry first.
        XCTAssertEqual(credits.usableCredits(now: now).map(\.expiresAt), [Date(timeIntervalSince1970: 1_793_270_000),
                                                                         Date(timeIntervalSince1970: 1_793_900_000)])
        XCTAssertEqual(ResetCreditText.countText(credits, now: now), "2회 사용 가능")
        let seoul = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        XCTAssertEqual(ResetCreditText.detailLines(credits, now: now, timeZone: seoul),
                       ["1회차 사용 기한: 10월 29일 오후 7:33", "2회차 사용 기한: 11월 6일 오전 2:33"])
        // A deadline in another year shows the year.
        XCTAssertEqual(ResetCreditText.deadline(Date(timeIntervalSince1970: 1_799_000_000), now: now, timeZone: seoul),
                       "2027년 1월 4일 오전 3:13")
    }

    func testExpiredAndNonAvailableResetCreditsAreNotCounted() throws {
        let now = Date(timeIntervalSince1970: 1_792_700_000)
        let data = codexResponse(#","rateLimitResetCredits":{"availableCount":3,"credits":[{"id":"a","grantedAt":1,"expiresAt":1792600000,"status":"available","resetType":"codexRateLimits"},{"id":"b","grantedAt":1,"expiresAt":null,"status":"available","resetType":"codexRateLimits"},{"id":"c","grantedAt":1,"expiresAt":1799000000,"status":"redeeming","resetType":"codexRateLimits"},{"id":"d","grantedAt":1,"expiresAt":1799000000,"status":"available","resetType":"unknown"}]}"#)
        let credits = try XCTUnwrap(try CodexRateLimitParser.parse(data, fetchedAt: now).resetCredits)
        // 3 reported − 1 listed as available but already expired; "redeeming" and non-Codex rows are not usable.
        XCTAssertEqual(credits.usableCount(now: now), 2)
        XCTAssertEqual(credits.usableCredits(now: now).count, 1)
        let lines = ResetCreditText.detailLines(credits, now: now)
        // Expired and non-available rows are not listed; the capped list is flagged instead of looking complete.
        XCTAssertEqual(lines, ["1회차 사용 기한 없음", "나머지 1회는 사용 기한 정보가 제공되지 않았습니다."])
    }

    func testZeroCountOnlyAndMissingResetCredits() throws {
        let now = Date(timeIntervalSince1970: 1_792_700_000)
        let zero = try XCTUnwrap(try CodexRateLimitParser.parse(
            codexResponse(#","rateLimitResetCredits":{"availableCount":0,"credits":[]}"#), fetchedAt: now).resetCredits)
        XCTAssertEqual(zero.usableCount(now: now), 0)
        XCTAssertEqual(ResetCreditText.countText(zero, now: now), "사용 가능 없음")
        XCTAssertEqual(ResetCreditText.detailLines(zero, now: now), [])
        // Count only: details null.
        let countOnly = try XCTUnwrap(try CodexRateLimitParser.parse(
            codexResponse(#","rateLimitResetCredits":{"availableCount":2,"credits":null}"#), fetchedAt: now).resetCredits)
        XCTAssertNil(countOnly.credits)
        XCTAssertEqual(ResetCreditText.countText(countOnly, now: now), "2회 사용 가능")
        XCTAssertEqual(ResetCreditText.detailLines(countOnly, now: now), ["사용 기한 정보는 제공되지 않았습니다."])
        // Field absent or null: no made-up values, just a notice.
        for extra in ["", #","rateLimitResetCredits":null"#] {
            let snapshot = try CodexRateLimitParser.parse(codexResponse(extra), fetchedAt: now)
            XCTAssertNil(snapshot.resetCredits)
            XCTAssertEqual(snapshot.windows.count, 2)
            XCTAssertEqual(ResetCreditText.detailLines(nil, now: now), ["Codex가 재설정 권한 정보를 제공하지 않았습니다."])
        }
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    @MainActor
    func testInvalidDisplayPreferencesUseSafeDefaults() throws {
        let suite = TestDefaults.suite("InvalidPreferences")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestDefaults.discard(defaults, suite: suite) }
        defaults.set("unknown-style", forKey: ProviderDisplaySettings.menuBarStyleKey)
        defaults.set("unknown-appearance", forKey: ProviderDisplaySettings.appearanceKey)
        let settings = ProviderDisplaySettings(defaults: defaults)
        XCTAssertEqual(settings.menuBarStyle, .numeric)
        XCTAssertEqual(settings.appearance, .system)
    }

    func testAGYNewStatusLineReceiptRecoversFromStaleFeed() throws {
        let received = Date(timeIntervalSince1970: 1_792_700_000)
        func payload(at date: Date) -> Data {
            let stamp = ISO8601DateFormatter().string(from: date)
            return Data(#"{"captured_at":"\#(stamp)","quota":{"gemini-weekly":{"remaining_fraction":0,"reset_time":null}}}"#.utf8)
        }
        let later = received.addingTimeInterval(901)
        XCTAssertThrowsError(try AGYQuotaParser.parse(payload(at: received), now: later)) {
            XCTAssertEqual($0 as? ExternalProviderError, .staleData)
        }
        let fresh = try AGYQuotaParser.parse(payload(at: later), now: later)
        guard case .quotas(let quotas) = fresh.metrics else { return XCTFail("Expected quota") }
        XCTAssertEqual(quotas.first?.remainingPercent, 0)
        XCTAssertEqual(fresh.fetchedAt, later)
    }

    func testCompactDateAcrossDayAndYearBoundary() {
        let zone = TimeZone(identifier: "Asia/Seoul")!
        let locale = Locale(identifier: "ko_KR")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let now = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23))!
        let tomorrow = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 9))!
        let later = calendar.date(from: DateComponents(year: 2027, month: 1, day: 3, hour: 9))!
        XCTAssertTrue(CompactDateTime.string(for: tomorrow, now: now, locale: locale, timeZone: zone).contains("내일"))
        XCTAssertTrue(CompactDateTime.string(for: later, now: now, locale: locale, timeZone: zone).contains("2027"))
    }

    @MainActor
    func testDecodedResponseProducesBothMenuBarValues() async throws {
        let data = Data(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":79,"windowDurationMins":300,"resetsAt":null},"secondary":{"usedPercent":84,"windowDurationMins":10080,"resetsAt":null}}}}"#.utf8)
        let snapshot = try CodexRateLimitParser.parse(data)
        let store = UsageStore(provider: SequenceProvider(responses: [.success(snapshot)]))
        if let task = store.refresh() { await task.value }
        XCTAssertEqual(store.menuBarText, "5h 21% · 7d 16%")
    }

    @MainActor
    func testRefreshSuccessThenFailureMarksPreviousData() async {
        let snapshot = UsageSnapshot(providerName: "Codex", windows: [
            UsageWindow(kind: .fiveHours, usedPercent: 71, resetsAt: nil),
            UsageWindow(kind: .sevenDays, usedPercent: 83, resetsAt: nil)
        ], fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let provider = SequenceProvider(responses: [.success(snapshot), .failure(.connection)])
        let store = UsageStore(provider: provider)
        if let task = store.refresh() { await task.value }
        XCTAssertEqual(store.menuBarText, "5h 29% · 7d 17%")
        XCTAssertNil(store.errorMessage)
        if let task = store.refresh() { await task.value }
        XCTAssertEqual(store.menuBarText, "이전 · 5h 29% · 7d 17%")
        XCTAssertEqual(store.snapshot?.fetchedAt, snapshot.fetchedAt)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testRefreshFailureWithoutPreviousDataShowsNoNumber() async {
        let store = UsageStore(provider: SequenceProvider(responses: [.failure(.cliUnavailable)]))
        if let task = store.refresh() { await task.value }
        XCTAssertEqual(store.menuBarText, "조회 실패")
        XCTAssertNil(store.snapshot)
        XCTAssertTrue(store.errorMessage?.contains("CLI") == true)
    }
}

private final class FakeLoginItemController: LoginItemControlling {
    var state: LoginItemState = .off
    var registerCalls = 0
    var unregisterCalls = 0
    var fail = false
    var failUnregister = false
    /// What `status` reports after a register call that did not throw (the system may still say otherwise).
    var stateAfterRegister: LoginItemState = .on

    func register() throws {
        registerCalls += 1
        if fail { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "fake register error"]) }
        state = stateAfterRegister
    }

    func unregister() throws {
        unregisterCalls += 1
        if failUnregister { throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "fake unregister error"]) }
        state = .off
    }
}

private struct StubAdminKeyStore: AdminKeyStoring {
    let key: String?
    func read() -> String? { key }
    func save(_ key: String) -> Bool { false }
    func delete() -> Bool { false }
}

private actor SequenceProvider: UsageProvider {
    let name = "Codex"
    private var responses: [Result<UsageSnapshot, UsageProviderError>]

    init(responses: [Result<UsageSnapshot, UsageProviderError>]) {
        self.responses = responses
    }

    func fetch() async throws -> UsageSnapshot {
        try responses.removeFirst().get()
    }
}

private actor CountingExternalProvider: ExternalUsageProvider {
    let id: ExternalProviderID = .antigravity
    private(set) var fetchCount = 0

    func fetch() async throws -> ExternalUsageSnapshot {
        fetchCount += 1
        return ExternalUsageSnapshot(
            metrics: .quotas([QuotaMetric(name: "gemini-weekly", remainingPercent: 50, resetsAt: nil)]),
            fetchedAt: Date()
        )
    }
}

/// Test-only preference suites, for every test that needs its own UserDefaults. A plain suite name lands in
/// ~/Library/Preferences, and even after `removePersistentDomain` cfprefsd later writes an empty `<suite>.plist`
/// there, so every run used to leave one file per suite (1,082 had piled up by Stage 6-9B). An absolute-path suite
/// keeps the file in a temporary folder instead; each name is unique, so parallel tests never share a suite.
enum TestDefaults {
    /// Files a crashed or killed run could not discard are swept on the next run once they are this old, so a
    /// suite still in use by a concurrent run is never touched.
    static let staleAge: TimeInterval = 3_600

    static let folder: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenlyTests-Preferences", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        sweepStale(in: url)
        return url
    }()

    static func suite(_ name: String) -> String {
        folder.appendingPathComponent("TokenlyTests.\(name).\(UUID().uuidString)").path
    }

    /// Only a suite made by `suite(_:)`: never the app's own domain, `standard`, or a plain name.
    static func isTestSuite(_ suite: String) -> Bool {
        suite.hasPrefix(folder.path + "/TokenlyTests.") && !suite.contains("/../")
    }

    static func discard(_ defaults: UserDefaults, suite: String) {
        guard isTestSuite(suite) else {
            assertionFailure("Refusing to clear a non-test preference domain: \(suite)")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(atPath: suite + ".plist")
    }

    private static func sweepStale(in folder: URL) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix("TokenlyTests.") && name.hasSuffix(".plist") {
            let path = folder.appendingPathComponent(name).path
            guard let modified = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) > staleAge else { continue }
            try? manager.removeItem(atPath: path)
        }
    }
}
