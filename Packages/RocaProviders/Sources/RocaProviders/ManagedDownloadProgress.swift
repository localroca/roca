import Foundation
import RocaCore

public struct ManagedDownloadProgress: Equatable, Sendable {
    public var completedBytes: Int64
    public var totalBytes: Int64?
    public var bytesPerSecond: Double
    public var currentItem: String?
    public var completedItems: Int
    public var totalItems: Int

    public init(
        completedBytes: Int64,
        totalBytes: Int64?,
        bytesPerSecond: Double,
        currentItem: String?,
        completedItems: Int,
        totalItems: Int
    ) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.currentItem = currentItem
        self.completedItems = completedItems
        self.totalItems = totalItems
    }
}

final class ManagedDownloadProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt = Date()
    private let totalItems: Int
    private let totalBytes: Int64?
    private let progress: (@Sendable (ManagedDownloadProgress) -> Void)?
    private var completedBytesBeforeCurrent: Int64 = 0
    private var completedItems: Int = 0
    private var currentItem: String?
    private var currentItemCompletedBytes: Int64 = 0
    private var currentItemExpectedBytes: Int64?

    init(
        totalItems: Int,
        totalBytes: Int64?,
        progress: (@Sendable (ManagedDownloadProgress) -> Void)?
    ) {
        self.totalItems = totalItems
        self.totalBytes = totalBytes
        self.progress = progress
    }

    func startItem(_ id: String, expectedBytes: Int64?) {
        lock.lock()
        currentItem = id
        currentItemExpectedBytes = expectedBytes
        currentItemCompletedBytes = 0
        let snapshot = makeSnapshotLocked()
        lock.unlock()
        progress?(snapshot)
    }

    func updateCurrentItem(completedBytes: Int64, expectedBytes: Int64?) {
        lock.lock()
        currentItemCompletedBytes = completedBytes
        if currentItemExpectedBytes == nil {
            currentItemExpectedBytes = expectedBytes
        }
        let snapshot = makeSnapshotLocked()
        lock.unlock()
        progress?(snapshot)
    }

    func finishCurrentItem(finalBytes: Int64?) {
        lock.lock()
        completedBytesBeforeCurrent += finalBytes ?? currentItemExpectedBytes ?? currentItemCompletedBytes
        completedItems += 1
        currentItem = nil
        currentItemExpectedBytes = nil
        currentItemCompletedBytes = 0
        let snapshot = makeSnapshotLocked()
        lock.unlock()
        progress?(snapshot)
    }

    private func makeSnapshotLocked() -> ManagedDownloadProgress {
        let completedBytes = completedBytesBeforeCurrent + currentItemCompletedBytes
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.25)
        return ManagedDownloadProgress(
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            bytesPerSecond: Double(completedBytes) / elapsed,
            currentItem: currentItem,
            completedItems: completedItems,
            totalItems: totalItems
        )
    }
}

func downloadRemoteFile(
    from url: URL,
    progress: (@Sendable (_ writtenBytes: Int64, _ expectedBytes: Int64?) -> Void)?
) async throws -> (URL, URLResponse) {
    let delegate = URLSessionDownloadDelegateBridge(progress: progress)
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    defer {
        session.finishTasksAndInvalidate()
    }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            delegate.start(url: url, session: session, continuation: continuation)
        }
    } onCancel: {
        delegate.cancel()
    }
}

private final class URLSessionDownloadDelegateBridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let progress: (@Sendable (_ writtenBytes: Int64, _ expectedBytes: Int64?) -> Void)?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var task: URLSessionDownloadTask?
    private var downloadedURL: URL?
    private var response: URLResponse?
    private var didResume = false

    init(progress: (@Sendable (_ writtenBytes: Int64, _ expectedBytes: Int64?) -> Void)?) {
        self.progress = progress
    }

    func start(
        url: URL,
        session: URLSession,
        continuation: CheckedContinuation<(URL, URLResponse), Error>
    ) {
        lock.lock()
        self.continuation = continuation
        let task = session.downloadTask(with: url)
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress?(
            totalBytesWritten,
            totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: false)
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                try FileManager.default.removeItem(at: temporaryURL)
            }
            try FileManager.default.moveItem(at: location, to: temporaryURL)

            lock.lock()
            downloadedURL = temporaryURL
            response = downloadTask.response
            lock.unlock()
        } catch {
            resume(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            resume(throwing: error)
            return
        }

        lock.lock()
        let downloadedURL = downloadedURL
        let response = response
        lock.unlock()

        guard let downloadedURL, let response else {
            resume(throwing: RocaError.assetInstallFailed("Download finished without a file."))
            return
        }

        resume(returning: (downloadedURL, response))
    }

    private func resume(returning value: (URL, URLResponse)) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    private func resume(throwing error: Error) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}
