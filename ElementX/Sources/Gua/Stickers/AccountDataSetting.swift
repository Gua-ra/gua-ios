//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

/// A value synced through global account data: shown at once from the session's cache, written optimistically with
/// rollback, and read from the store after syncs, as the SDK can't observe custom account data.
final class AccountDataSetting<Value: Equatable & Sendable> {
    let accountDataType: String
    
    private let clientProxy: ClientProxyProtocol
    private let cache: AccountDataCacheProtocol
    private let decode: (String?) -> Value
    private let encode: (Value) -> String
    private let echoTimeout: TimeInterval
    private let syncThrottle: DispatchQueue.SchedulerTimeType.Stride
    private let subject: CurrentValueSubject<Value, Never>
    
    private var pendingValue: Value?
    private var fallbackValue: Value
    private var echoDeadline: Date?
    private var latestRequest = 0
    private var writeTask: Task<Result<Void, ClientProxyError>, Never>?
    private var hasConfirmedWrite = false
    
    private var isRefreshing = false
    private var needsRefresh = false
    private var hasSynced = false
    private var isStarted = false
    
    private var cancellables = Set<AnyCancellable>()
    
    var valuePublisher: CurrentValuePublisher<Value, Never> {
        subject.asCurrentValuePublisher()
    }
    
    /// `decode` reads nil as nothing stored.
    init(accountDataType: String,
         clientProxy: ClientProxyProtocol,
         cache: AccountDataCacheProtocol,
         decode: @escaping (String?) -> Value,
         encode: @escaping (Value) -> String,
         echoTimeout: TimeInterval = 30,
         syncThrottle: DispatchQueue.SchedulerTimeType.Stride = .seconds(5)) {
        self.accountDataType = accountDataType
        self.clientProxy = clientProxy
        self.cache = cache
        self.decode = decode
        self.encode = encode
        self.echoTimeout = echoTimeout
        self.syncThrottle = syncThrottle
        
        let cachedValue = decode(cache.load(type: accountDataType))
        subject = CurrentValueSubject(cachedValue)
        fallbackValue = cachedValue
    }
    
    func start() {
        guard !isStarted else { return }
        isStarted = true
        
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
    
    func set(_ value: Value) async -> Result<Void, ClientProxyError> {
        // The echo is compared with the stored form.
        let value = decode(encode(value))
        if pendingValue == nil {
            fallbackValue = subject.value
        }
        pendingValue = value
        echoDeadline = nil
        latestRequest += 1
        apply(value)
        
        let request = latestRequest
        let previousWrite = writeTask
        let task = Task { [weak self] () -> Result<Void, ClientProxyError> in
            _ = await previousWrite?.value
            guard let self else { return .success(()) }
            return await write(value, request: request)
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
            await applyStoredValue()
        } while needsRefresh
        isRefreshing = false
    }
    
    private func write(_ value: Value, request: Int) async -> Result<Void, ClientProxyError> {
        // A newer value is already queued, so this one is never sent.
        guard request == latestRequest else { return .success(()) }
        
        let result = await clientProxy.setAccountData(type: accountDataType, content: encode(value))
        if case .success = result {
            fallbackValue = value
            hasConfirmedWrite = true
        }
        guard request == latestRequest else { return result }
        
        switch result {
        case .success:
            echoDeadline = Date.now.addingTimeInterval(echoTimeout)
        case .failure(let error):
            MXLog.error("Failed storing \(accountDataType): \(error)")
            pendingValue = nil
            apply(fallbackValue)
        }
        return result
    }
    
    private func applyStoredValue() async {
        // Captured before the read: a sync landing meanwhile reruns it.
        let canClear = hasSynced
        guard case .success(let content) = await clientProxy.accountData(type: accountDataType) else { return }
        let storedValue = content.map(decode)
        
        if let pendingValue {
            guard writeTask == nil, let echoDeadline, storedValue == pendingValue || echoDeadline <= Date.now else { return }
            self.pendingValue = nil
            self.echoDeadline = nil
        }
        
        if let storedValue {
            fallbackValue = storedValue
            apply(storedValue)
        } else if !hasConfirmedWrite, canClear {
            // Before the first sync, nothing stored may only mean the account data has not arrived yet.
            let emptyValue = decode(nil)
            fallbackValue = emptyValue
            apply(emptyValue)
        }
    }
    
    private func apply(_ value: Value) {
        guard value != subject.value else { return }
        subject.send(value)
        cache.save(encode(value), type: accountDataType)
    }
}
