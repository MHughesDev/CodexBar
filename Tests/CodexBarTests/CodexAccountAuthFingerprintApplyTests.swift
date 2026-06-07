import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `same account token refresh fingerprint change keeps codex usage success`() async {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-token-refresh-fingerprint-change")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        let staleReconciliationSnapshot = settings.codexAccountReconciliationSnapshot

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: .liveSystem,
            loadedAt: Date(),
            snapshot: staleReconciliationSnapshot)
        await blocker.resume(with: .success(self.codexSnapshot(email: "alpha@example.com", usedPercent: 25)))
        await refreshTask.value

        #expect(store.snapshots[.codex]?.primary?.usedPercent == 25)
        #expect(store.lastCodexAccountScopedRefreshGuard?.authFingerprint == "new-token-material")
        #expect(store.errors[.codex] == nil)
    }

    @Test
    func `same account token refresh fingerprint change discards codex usage failure`() async {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-token-refresh-fingerprint-failure")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        let staleReconciliationSnapshot = settings.codexAccountReconciliationSnapshot

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: .liveSystem,
            loadedAt: Date(),
            snapshot: staleReconciliationSnapshot)
        await blocker.resume(with: .failure(TestRefreshError(message: "old token failure")))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
    }

    @Test
    func `same account token refresh fingerprint change keeps codex credits success`() async {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-token-refresh-credits-success")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))

        let store = self.makeUsageStore(settings: settings)
        store._test_codexCreditsLoaderOverride = {
            settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
                email: "alpha@example.com",
                authFingerprint: "new-token-material",
                codexHomePath: "/Users/test/.codex",
                observedAt: Date(),
                identity: .providerAccount(id: "acct-alpha"))
            return CreditsSnapshot(remaining: 42, events: [], updatedAt: Date())
        }
        defer { store._test_codexCreditsLoaderOverride = nil }

        await store.refreshCreditsIfNeeded()

        #expect(store.credits?.remaining == 42)
        #expect(store.lastCreditsSnapshotAccountKey == "alpha@example.com")
        #expect(store.lastCodexAccountScopedRefreshGuard?.authFingerprint == "new-token-material")
        #expect(store.lastCreditsError == nil)
    }

    @Test
    func `stacked visible refresh discards selected failure after managed token fingerprint rotates`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-selected-managed-token-failure")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-444444444444"))
        let siblingID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-333333333333"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-managed-token-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-managed-token-sibling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: targetHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingHome, withIntermediateDirectories: true)
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "managed-token@example.com",
            providerAccountID: "acct-managed-token",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-token",
            authFingerprint: "old-managed-token",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let updatedTarget = ManagedCodexAccount(
            id: targetID,
            email: "managed-token@example.com",
            providerAccountID: "acct-managed-token",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-token",
            authFingerprint: "new-managed-token",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 3,
            lastAuthenticatedAt: 3)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "managed-token-sibling@example.com",
            providerAccountID: "acct-managed-token-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-managed-token-sibling",
            authFingerprint: "sibling-managed-token",
            managedHomePath: siblingHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [targetAccount, siblingAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: targetHome)
            try? FileManager.default.removeItem(at: siblingHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: targetID)

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let blocker = BlockingCodexFetchStrategy()
        let targetHomePath = targetHome.path
        let now = Date()
        self.installContextualCodexProvider(on: store) { context in
            if context.env["CODEX_HOME"] == targetHomePath {
                return try await blocker.awaitResult()
            }
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 9,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "managed-token-sibling@example.com",
                    accountOrganization: nil,
                    loginMethod: "Sibling Team"))
        }

        let refreshTask = Task { await store.refreshCodexVisibleAccountsForMenu() }
        await blocker.waitUntilStarted()
        try FileManagedCodexAccountStore(fileURL: storeURL).storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [updatedTarget, siblingAccount]))
        await blocker.resume(with: .failure(TestRefreshError(message: "old managed token failure")))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
        #expect(!store.codexAccountSnapshots.contains {
            $0.account.workspaceAccountID == "acct-managed-token"
        })
        #expect(!snapshotStore.storedSnapshots.contains {
            $0.account.workspaceAccountID == "acct-managed-token"
        })
    }

    @Test
    func `stale auth fingerprint cache at refresh start keeps current codex usage success`() async {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-stale-start-cache-current-auth")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-email-only-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "alpha@example.com"))
        let staleReconciliationSnapshot = settings.codexAccountReconciliationSnapshot
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-email-only-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "alpha@example.com"))
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: .liveSystem,
            loadedAt: Date(),
            snapshot: staleReconciliationSnapshot)

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        await blocker.resume(with: .success(self.codexSnapshot(email: "alpha@example.com", usedPercent: 33)))
        await refreshTask.value

        #expect(store.snapshots[.codex]?.primary?.usedPercent == 33)
        #expect(store.lastCodexAccountScopedRefreshGuard?.authFingerprint == "new-email-only-auth")
        #expect(store.errors[.codex] == nil)
    }

    @Test
    func `same provider account live email change discards stale codex usage success`() async {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-provider-email-change")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "old@example.com",
            authFingerprint: "old-provider-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-shared"))
        let staleReconciliationSnapshot = settings.codexAccountReconciliationSnapshot

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "new@example.com",
            authFingerprint: "new-provider-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-shared"))
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: .liveSystem,
            loadedAt: Date(),
            snapshot: staleReconciliationSnapshot)
        await blocker.resume(with: .success(self.codexSnapshot(email: "old@example.com", usedPercent: 25)))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
    }

    @Test
    func `same email email-only auth fingerprint switch discards stale codex usage success`() async {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-email-only-fingerprint-switch")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-email-only-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "alpha@example.com"))
        let staleReconciliationSnapshot = settings.codexAccountReconciliationSnapshot

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-email-only-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "alpha@example.com"))
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: .liveSystem,
            loadedAt: Date(),
            snapshot: staleReconciliationSnapshot)
        await blocker.resume(with: .success(self.codexSnapshot(email: "alpha@example.com", usedPercent: 25)))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
    }
}
