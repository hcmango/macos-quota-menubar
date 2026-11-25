import Foundation
import OSLog

/// Queries Antigravity CLI (`agy`) quotas and AI credits via official headless slash commands.
/// Credentials and OAuth flows remain owned by `agy`.
struct AgyQuotaClient {
    static var isInstalled: Bool { (try? agyExecutableURL()) != nil }

    func readQuota() async throws -> AgyQuotaSnapshot {
        try await Task.detached(priority: .userInitiated) {
            let usageData: Data
            do {
                usageData = try runAgyCommand(
                    arguments: ["-p", "/usage", "--output-format", "json", "--print-timeout", "15s"],
                    timeout: 20
                )
            } catch AgyQuotaError.timeout {
                try await Task.sleep(for: .seconds(1))
                usageData = try runAgyCommand(
                    arguments: ["-p", "/usage", "--output-format", "json", "--print-timeout", "15s"],
                    timeout: 20
                )
            }

            let groups = try Self.parseUsage(usageData)

            // Fetch AI credits serially to avoid concurrent CLI session contention;
            // credits failure is non-fatal when quota data was already fetched.
            let credits: Double? = try? {
                let creditsData = try runAgyCommand(
                    arguments: ["-p", "/credits", "--output-format", "json", "--print-timeout", "15s"],
                    timeout: 15
                )
                return try Self.parseCredits(creditsData)
            }()

            return AgyQuotaSnapshot(
                groups: groups,
                remainingCredits: credits,
                errorMessage: nil
            )
        }.value
    }

    static func parseUsage(_ data: Data) throws -> [AgyQuotaGroup] {
        let envelope: AgyCommandEnvelope<AgyUsageData>
        do {
            envelope = try JSONDecoder().decode(AgyCommandEnvelope<AgyUsageData>.self, from: data)
        } catch {
            throw AgyQuotaError.invalidResponse("无法解析 agy 用量输出")
        }

        if envelope.status.uppercased() != "SUCCESS" {
            let message = envelope.error?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgyQuotaError.cliError(message?.isEmpty == false ? message! : "agy 返回异常状态：\(envelope.status)")
        }

        guard let rawGroups = envelope.command?.data?.groups else {
            throw AgyQuotaError.invalidResponse("agy 用量输出缺少额度分组")
        }

        return rawGroups.map { rawGroup in
            let buckets: [AgyQuotaBucket] = (rawGroup.buckets ?? []).compactMap { rawBucket in
                guard let remaining = rawBucket.remainingFraction, remaining.isFinite else { return nil }
                return AgyQuotaBucket(
                    id: rawBucket.id,
                    window: rawBucket.window ?? "",
                    remainingFraction: remaining,
                    resetAt: rawBucket.resetTime.flatMap(parseISO8601Date)
                )
            }
            return AgyQuotaGroup(name: rawGroup.name, buckets: buckets)
        }
    }

    static func parseCredits(_ data: Data) throws -> Double {
        let envelope: AgyCommandEnvelope<AgyCreditsData>
        do {
            envelope = try JSONDecoder().decode(AgyCommandEnvelope<AgyCreditsData>.self, from: data)
        } catch {
            throw AgyQuotaError.invalidResponse("无法解析 agy Credits 输出")
        }

        if envelope.status.uppercased() != "SUCCESS" {
            let message = envelope.error?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgyQuotaError.cliError(message?.isEmpty == false ? message! : "agy 返回异常状态：\(envelope.status)")
        }

        guard let credits = envelope.command?.data?.remainingCredits, credits.isFinite else {
            throw AgyQuotaError.invalidResponse("agy Credits 输出缺少余额字段")
        }

        return credits
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

func agyExecutableURL(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> URL {
    var candidates = [
        homeDirectory.appendingPathComponent(".local/bin/agy").path,
        "/opt/homebrew/bin/agy",
        "/usr/local/bin/agy"
    ]

    if let pathEnv = environment["PATH"] {
        for directory in pathEnv.split(separator: ":").map(String.init) where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("agy").path
            if !candidates.contains(candidate) {
                candidates.append(candidate)
            }
        }
    }

    if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
        return URL(fileURLWithPath: path)
    }

    throw AgyQuotaError.executableNotFound
}

func runAgyCommand(
    executableURL: URL? = nil,
    arguments: [String],
    timeout: TimeInterval = 20,
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
) throws -> Data {
    let process = Process()
    process.executableURL = try executableURL ?? agyExecutableURL()
    process.arguments = arguments
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    // Strip inherited SSH session variables so `agy` uses the desktop Keychain
    // instead of assuming a headless SSH session when launched from a shell.
    var environment = baseEnvironment
    environment.removeValue(forKey: "SSH_CLIENT")
    environment.removeValue(forKey: "SSH_CONNECTION")
    environment.removeValue(forKey: "SSH_TTY")
    process.environment = environment

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout
    process.standardError = stderr

    let state = AgyProcessOutput()
    let logger = Logger(subsystem: "com.hcmango.QuotaBar", category: "agy")

    stdout.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        state.condition.lock()
        defer { state.condition.unlock() }
        if data.isEmpty {
            state.stdoutClosed = true
            handle.readabilityHandler = nil
        } else {
            state.stdoutData.append(data)
        }
        state.condition.broadcast()
    }

    stderr.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        state.condition.lock()
        defer { state.condition.unlock() }
        if data.isEmpty {
            state.stderrClosed = true
            handle.readabilityHandler = nil
        } else {
            state.stderrData.append(data)
            state.stderrData = Data(state.stderrData.suffix(4096))
            let text = String(decoding: state.stderrData, as: UTF8.self)
            if text.contains("Authentication required") || text.contains("Waiting for authentication") {
                state.authRequired = true
            }
        }
        state.condition.broadcast()
    }

    process.terminationHandler = { _ in
        state.condition.lock()
        state.terminated = true
        state.condition.broadcast()
        state.condition.unlock()
    }

    defer {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        if process.isRunning {
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
    }

    try process.run()

    let deadline = Date().addingTimeInterval(timeout)
    state.condition.lock()
    defer { state.condition.unlock() }

    while true {
        if state.authRequired {
            logger.info("agy requires interactive sign-in; aborting headless refresh")
            throw AgyQuotaError.signedOut
        }
        if state.terminated && state.stdoutClosed && state.stderrClosed {
            break
        }
        if Date() >= deadline {
            let diagnostics = String(decoding: state.stderrData, as: UTF8.self)
            logger.error("agy timed out: \(diagnostics, privacy: .private)")
            throw AgyQuotaError.timeout("agy 查询超时（\(Int(timeout))秒）")
        }
        _ = state.condition.wait(until: deadline)
    }

    let outputData = state.stdoutData
    let errorText = String(decoding: state.stderrData, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    if process.terminationStatus != 0 {
        if let envelope = try? JSONDecoder().decode(AgyErrorEnvelope.self, from: outputData),
           let message = envelope.error?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            if message.localizedCaseInsensitiveContains("authentication required")
                || message.localizedCaseInsensitiveContains("not authenticated") {
                throw AgyQuotaError.signedOut
            }
            throw AgyQuotaError.cliError(message)
        }
        if errorText.localizedCaseInsensitiveContains("authentication required")
            || errorText.localizedCaseInsensitiveContains("not authenticated") {
            throw AgyQuotaError.signedOut
        }
        logger.error("agy exited with status \(process.terminationStatus): \(errorText, privacy: .private)")
        throw AgyQuotaError.processFailed(errorText.isEmpty ? "agy 进程退出（\(process.terminationStatus)）" : errorText)
    }

    return outputData
}

private final class AgyProcessOutput {
    let condition = NSCondition()
    var stdoutData = Data()
    var stderrData = Data()
    var stdoutClosed = false
    var stderrClosed = false
    var terminated = false
    var authRequired = false
}

private struct AgyErrorEnvelope: Decodable {
    let status: String?
    let error: String?
}

private struct AgyCommandEnvelope<DataPayload: Decodable>: Decodable {
    let status: String
    let error: String?
    let command: Command?

    struct Command: Decodable {
        let name: String
        let data: DataPayload?
    }
}

private struct AgyUsageData: Decodable {
    let groups: [Group]?

    struct Group: Decodable {
        let name: String
        let buckets: [Bucket]?
    }

    struct Bucket: Decodable {
        let id: String
        let window: String?
        let remainingFraction: Double?
        let resetTime: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case window
            case remainingFraction = "remaining_fraction"
            case resetTime = "reset_time"
        }
    }
}

private struct AgyCreditsData: Decodable {
    let remainingCredits: Double?

    private enum CodingKeys: String, CodingKey {
        case remainingCredits = "remaining_credits"
    }
}

enum AgyQuotaError: LocalizedError, Equatable {
    case executableNotFound
    case signedOut
    case timeout(String)
    case processFailed(String)
    case invalidResponse(String)
    case cliError(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "未找到 agy 可执行文件"
        case .signedOut:
            return "请先在终端运行 agy 登录"
        case let .timeout(message):
            return message
        case let .processFailed(message):
            return message
        case let .invalidResponse(message):
            return message
        case let .cliError(message):
            return message
        }
    }
}
