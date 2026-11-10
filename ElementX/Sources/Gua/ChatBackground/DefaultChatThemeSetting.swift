//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

/// The theme of every chat without one of its own, private to the user and synced through global account data.
@MainActor
final class DefaultChatThemeSetting {
    static let accountDataType = "global.gua.chat_theme"

    private let clientProxy: ClientProxyProtocol
    private let cache: ChatBackgroundCacheProtocol
    private let echoTimeout: TimeInterval
    private let syncThrottle: DispatchQueue.SchedulerTimeType.Stride
    private let subject: CurrentValueSubject<ChatTheme, Never>

    private var pendingTheme: ChatTheme?
    private var fallbackTheme: ChatTheme
    private var echoDeadline: Date?
    private var latestRequest = 0
    private var writeTask: Task<Result<Void, ClientProxyError>, Never>?
    private var hasConfirmedWrite = false

    private var isRefreshing = false
    private var needsRefresh = false
    private var hasSynced = false

    private var cancellables = Set<AnyCancellable>()

    var themePublisher: CurrentValuePublisher<ChatTheme, Never> {
        subject.asCurrentValuePublisher()
    }

    init(clientProxy: ClientProxyProtocol,
         cache: ChatBackgroundCacheProtocol,
         echoTimeout: TimeInterval = 30,
         syncThrottle: DispatchQueue.SchedulerTimeType.Stride = .seconds(5)) {
        self.clientProxy = clientProxy
        self.cache = cache
        self.echoTimeout = echoTimeout
        self.syncThrottle = syncThrottle

        let cachedTheme = ChatTheme(contentJSON: cache.loadDefaultTheme())
        subject = CurrentValueSubject(cachedTheme)
        fallbackTheme = cachedTheme
    }

    /// Reads the store now and after syncs, as the SDK can't observe custom account data.
    func start() {
        clientProxy.actionsPublisher
            .filter(\.isSyncUpdate)
            .map { _ in true }
            .prepend(false)
            .throttle(for: syncThrottle, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] afterSync in
                Task { await self?.refresh(afterSync: afterSync) }
            }
            .store(in: &cancellables)
    }

    func set(_ theme: ChatTheme) async -> Result<Void, ClientProxyError> {
        // The stored form rounds a photo's dim and position, and the echo must match it.
        let theme = ChatTheme(contentJSON: theme.contentJSON)
        if pendingTheme == nil {
            fallbackTheme = subject.value
        }
        pendingTheme = theme
        echoDeadline = nil
        latestRequest += 1
        apply(theme)

        let request = latestRequest
        let previousWrite = writeTask
        let task = Task { [weak self] () -> Result<Void, ClientProxyError> in
            _ = await previousWrite?.value
            guard let self else { return .success(()) }
            return await write(theme, request: request)
        }
        writeTask = task

        let result = await task.value
        if writeTask == task {
            writeTask = nil
        }
        return result
    }

    func refresh(afterSync: Bool = false) async {
        hasSynced = hasSynced || afterSync
        guard !isRefreshing else {
            needsRefresh = true
            return
        }

        isRefreshing = true
        repeat {
            needsRefresh = false
            await applyStoredTheme()
        } while needsRefresh
        isRefreshing = false
    }

    private func write(_ theme: ChatTheme, request: Int) async -> Result<Void, ClientProxyError> {
        // A newer choice is already queued, so this one is never sent.
        guard request == latestRequest else { return .success(()) }

        let result = await clientProxy.setAccountData(type: Self.accountDataType, content: theme.contentJSON)
        if case .success = result {
            fallbackTheme = theme
            hasConfirmedWrite = true
        }
        guard request == latestRequest else { return result }

        switch result {
        case .success:
            echoDeadline = Date.now.addingTimeInterval(echoTimeout)
        case .failure(let error):
            MXLog.error("Failed storing the default chat theme: \(error)")
            pendingTheme = nil
            apply(fallbackTheme)
        }
        return result
    }

    private func applyStoredTheme() async {
        // Captured before the read: a sync landing meanwhile reruns it.
        let canClear = hasSynced
        guard case .success(let content) = await clientProxy.accountData(type: Self.accountDataType) else { return }
        let storedTheme = content.map(ChatTheme.init(contentJSON:))

        if let pendingTheme {
            guard writeTask == nil, let echoDeadline else { return }
            guard storedTheme == pendingTheme || echoDeadline <= Date.now else { return }
            self.pendingTheme = nil
            self.echoDeadline = nil
        }

        if let storedTheme {
            fallbackTheme = storedTheme
            apply(storedTheme)
        } else if !hasConfirmedWrite, canClear {
            // Before the first sync, nothing stored may only mean the account data has not arrived yet.
            fallbackTheme = .stock
            apply(.stock)
        }
    }

    private func apply(_ theme: ChatTheme) {
        guard theme != subject.value else { return }
        subject.send(theme)
        cache.saveDefaultTheme(theme.contentJSON)
    }
}
