import Foundation

/// File-system boundary shared by export request validation and final output
/// publication. Keeping this independent from AVFoundation makes stale-temp
/// and path-alias behavior deterministic and directly testable.
enum ExportFileTransaction {
    struct Output {
        let temporaryURL: URL
        let finalURL: URL
    }

    static func collides(outputURL: URL, inputURLs: [URL]) -> Bool {
        let outputPath = canonicalPath(outputURL)
        return inputURLs.contains { canonicalPath($0) == outputPath }
    }

    static func makeTemporaryURL(for finalURL: URL) -> URL {
        let folder = finalURL.deletingLastPathComponent()
        let base = finalURL.deletingPathExtension().lastPathComponent
        let fileExtension = finalURL.pathExtension.isEmpty ? "mp4" : finalURL.pathExtension
        return folder.appendingPathComponent(
            ".\(base).dogsc-export-\(UUID().uuidString.lowercased()).tmp.\(fileExtension)"
        )
    }

    static func promote(temporaryURL: URL, to finalURL: URL) throws {
        try promote([Output(temporaryURL: temporaryURL, finalURL: finalURL)])
    }

    /// A filesystem cannot atomically rename several unrelated files at once.
    /// Prepare backups before publishing anything, then restore every attempted
    /// destination if a later publication fails. The synchronous commit is not
    /// interrupted by cancellation between outputs.
    static func promote(_ outputs: [Output]) throws {
        let fileManager = FileManager.default
        var destinations = Set<String>()
        let temporaryPaths = Set(outputs.map { canonicalPath($0.temporaryURL) })
        guard temporaryPaths.count == outputs.count else {
            throw TransactionError.invalidOutputPaths
        }
        for output in outputs {
            try rejectDirectory(at: output.finalURL, fileManager: fileManager)
            let path = canonicalPath(output.finalURL)
            guard destinations.insert(path).inserted, !temporaryPaths.contains(path) else {
                throw TransactionError.invalidOutputPaths
            }
        }

        var backups: [Backup] = []
        var attempted: [Int] = []
        do {
            // Copying an existing destination leaves it untouched if creating
            // any backup fails. Backups stay on the destination volume.
            for output in outputs {
                let backupURL = fileManager.fileExists(atPath: output.finalURL.path)
                    ? makeBackupURL(for: output.finalURL) : nil
                backups.append(Backup(finalURL: output.finalURL, backupURL: backupURL))
                if let backupURL {
                    try fileManager.copyItem(at: output.finalURL, to: backupURL)
                }
            }
            for (index, output) in outputs.enumerated() {
                // Include an attempted replace in rollback even if the OS
                // reports an error after it has changed the destination.
                attempted.append(index)
                try publish(temporaryURL: output.temporaryURL, to: output.finalURL,
                    fileManager: fileManager)
            }
        } catch {
            let publicationError = error
            var failedRestorations: [URL] = []
            for index in attempted.reversed() {
                let backup = backups[index]
                do {
                    if let backupURL = backup.backupURL {
                        try publish(temporaryURL: backupURL, to: backup.finalURL,
                            fileManager: fileManager)
                    } else if fileManager.fileExists(atPath: backup.finalURL.path) {
                        try fileManager.removeItem(at: backup.finalURL)
                    }
                } catch {
                    failedRestorations.append(backup.backupURL ?? backup.finalURL)
                }
            }
            let retainedPaths = Set(failedRestorations.map(\.path))
            for backup in backups {
                if let url = backup.backupURL, !retainedPaths.contains(url.path) {
                    try? fileManager.removeItem(at: url)
                }
            }
            if !failedRestorations.isEmpty {
                throw TransactionError.rollbackFailed(
                    reason: publicationError.localizedDescription,
                    recoveryPaths: failedRestorations.map(\.path)
                )
            }
            throw publicationError
        }
        for backup in backups {
            if let url = backup.backupURL { try? fileManager.removeItem(at: url) }
        }
    }

    private static func publish(temporaryURL: URL, to finalURL: URL,
        fileManager: FileManager) throws {
        try rejectDirectory(at: finalURL, fileManager: fileManager)
        if fileManager.fileExists(atPath: finalURL.path) {
            _ = try fileManager.replaceItemAt(finalURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
        }
    }

    private static func rejectDirectory(at url: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw TransactionError.directoryDestination(url.path)
        }
    }

    private static func makeBackupURL(for finalURL: URL) -> URL {
        finalURL.deletingLastPathComponent().appendingPathComponent(
            ".\(finalURL.lastPathComponent).dogsc-export-backup-\(UUID().uuidString.lowercased())"
        )
    }

    private struct Backup {
        let finalURL: URL
        let backupURL: URL?
    }

    private enum TransactionError: LocalizedError {
        case invalidOutputPaths
        case directoryDestination(String)
        case rollbackFailed(reason: String, recoveryPaths: [String])

        var errorDescription: String? {
            switch self {
            case .invalidOutputPaths:
                return "导出临时文件与目标路径不能重复或重叠。"
            case let .directoryDestination(path):
                return "导出目标是文件夹，无法替换：\(path)"
            case let .rollbackFailed(reason, recoveryPaths):
                return "导出文件发布失败：\(reason)。部分文件恢复失败，恢复文件保留在：\(recoveryPaths.joined(separator: "、"))"
            }
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
