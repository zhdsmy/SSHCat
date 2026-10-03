import Foundation

/// An observed failed connection attempt, not a continuous health check.
public struct SSHForwardFailure: Equatable, Sendable {
    public enum Reason: Equatable, Sendable { case refused, timedOut, unreachable }
    public let forwardID: UUID?
    public let reason: Reason
    public let line: String

    public var message: String {
        switch reason {
        case .refused: return L10n.core("target.refused")
        case .timedOut: return L10n.core("target.timed_out")
        case .unreachable: return L10n.core("target.unreachable")
        }
    }

    public static func parse(_ line: String, forwards: [PortForward]) -> SSHForwardFailure? {
        let text = line.lowercased()
        guard (text.hasPrefix("channel ") && text.contains("open failed: connect failed:")) || text.hasPrefix("connect_to ") else {
            return nil
        }
        let reason: Reason
        if text.contains("connection refused") { reason = .refused }
        else if text.contains("timed out") { reason = .timedOut }
        else if text.contains("failed") { reason = .unreachable }
        else { return nil }
        var forwardID: UUID?
        let pattern = try! NSRegularExpression(pattern: #"^connect_to (.+) port (\d+):"#)
        let ns = line as NSString
        if let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
           let port = Int(ns.substring(with: match.range(at: 2))) {
            let host = ns.substring(with: match.range(at: 1)).lowercased()
            let matches = forwards.filter {
                $0.kind == .remote && $0.targetPort == port &&
                    SSHToken.forwardAddress($0.targetHost).lowercased() == SSHToken.forwardAddress(host)
            }
            if matches.count == 1 { forwardID = matches[0].id }
        }
        // VERBOSE channel errors lack an endpoint; inherited config forwards also make guesses unsafe.
        return SSHForwardFailure(forwardID: forwardID, reason: reason, line: line)
    }
}
