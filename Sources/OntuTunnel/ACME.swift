import CryptoKit
import Foundation

struct DNSError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// How the domain is proven.
enum ChallengeMode {
    /// File at http://<domain>/.well-known/acme-challenge/<token>, served by
    /// OntuTunnel's own proxy — works with any DNS host, no API needed.
    case http(publish: (String, String) -> Void, remove: (String) -> Void)
}

/// Minimal Let's Encrypt (ACME v2, RFC 8555) client using HTTP-01: the
/// check file is served by OntuTunnel's own proxy on port 80.
final class ACMEClient {
    static let production = URL(string: "https://acme-v02.api.letsencrypt.org/directory")!
    static let staging = URL(string: "https://acme-staging-v02.api.letsencrypt.org/directory")!

    private let directoryURL: URL
    private let accountKey: P256.Signing.PrivateKey
    private(set) var kid: String?
    private var directory: [String: Any] = [:]
    private var nonce: String?
    private let log: (String) -> Void

    init(staging: Bool, accountKey: P256.Signing.PrivateKey, kid: String?, log: @escaping (String) -> Void) {
        directoryURL = staging ? Self.staging : Self.production
        self.accountKey = accountKey
        self.kid = kid
        self.log = log
    }

    // MARK: - Public flow

    /// Returns the PEM certificate chain for `names`, signed for `certKey`.
    func issue(names: [String], email: String, mode: ChallengeMode,
               certKey: P256.Signing.PrivateKey) async throws -> String {
        try await loadDirectory()
        try await ensureAccount(email: email)

        log("Ordering certificate for " + names.joined(separator: ", "))
        let identifiers = names.map { ["type": "dns", "value": $0] }
        let (orderData, orderResp) = try await post(url("newOrder"), payload: ["identifiers": identifiers])
        guard let orderURL = orderResp.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)),
              let order = json(orderData),
              let authzURLs = (order["authorizations"] as? [String])?.compactMap(URL.init(string:)),
              let finalizeURL = (order["finalize"] as? String).flatMap(URL.init(string:))
        else { throw DNSError(message: "Let's Encrypt: unexpected order reply.") }

        let challengeType = "http-01"

        struct Pending { let authz: URL; let challenge: URL; let ident: String; let token: String; let keyAuth: String }
        var pending: [Pending] = []
        for authz in authzURLs {
            let (data, _) = try await post(authz, payload: nil)
            guard let a = json(data), let ident = (a["identifier"] as? [String: Any])?["value"] as? String else { continue }
            if (a["status"] as? String) == "valid" { continue }
            guard let ch = (a["challenges"] as? [[String: Any]])?.first(where: { ($0["type"] as? String) == challengeType }),
                  let token = ch["token"] as? String, let chURL = (ch["url"] as? String).flatMap(URL.init(string:))
            else {
                throw DNSError(message: "Let's Encrypt offered no \(challengeType) challenge for \(ident).")
            }
            pending.append(Pending(authz: authz, challenge: chURL, ident: ident, token: token, keyAuth: token + "." + thumbprint))
        }

        switch mode {
        case .http(let publish, let remove):
            for p in pending { publish(p.token, p.keyAuth) }
            defer { for p in pending { remove(p.token) } }
            log("Let's Encrypt will now open http://<domain>/.well-known/acme-challenge/… from the internet")
            try await answer(pending.map { ($0.challenge, $0.authz, $0.ident) })
        }

        log("Finalizing")
        let csr = try CSR.build(names: names, key: certKey)
        _ = try await post(finalizeURL, payload: ["csr": b64u(csr)])
        let final = try await poll(orderURL, until: "valid", what: "Certificate order")
        guard let certURL = (final["certificate"] as? String).flatMap(URL.init(string:)) else {
            throw DNSError(message: "Let's Encrypt: no certificate URL.")
        }
        let (pem, _) = try await post(certURL, payload: nil, accept: "application/pem-certificate-chain")
        guard let text = String(data: pem, encoding: .utf8), text.contains("BEGIN CERTIFICATE") else {
            throw DNSError(message: "Let's Encrypt: certificate download failed.")
        }
        log("Certificate issued")
        return text
    }

    private func answer(_ items: [(challenge: URL, authz: URL, ident: String)]) async throws {
        for item in items { _ = try await post(item.challenge, payload: [String: Any]()) }
        for item in items { try await poll(item.authz, until: "valid", what: "Validation of \(item.ident)") }
    }

    // MARK: - Account

    private func ensureAccount(email: String) async throws {
        if kid != nil { return }
        var payload: [String: Any] = ["termsOfServiceAgreed": true]
        if !email.isEmpty { payload["contact"] = ["mailto:\(email)"] }
        let (_, resp) = try await post(url("newAccount"), payload: payload, useJWK: true)
        guard let location = resp.value(forHTTPHeaderField: "Location") else {
            throw DNSError(message: "Let's Encrypt: account was not created.")
        }
        kid = location
        log("Let's Encrypt account ready")
    }

    // MARK: - Waiting

    @discardableResult
    private func poll(_ url: URL, until target: String, what: String) async throws -> [String: Any] {
        for _ in 0..<60 {
            let (data, _) = try await post(url, payload: nil)
            guard let obj = json(data) else { break }
            let status = obj["status"] as? String ?? ""
            if status == target { return obj }
            if status == "invalid" {
                let detail = ((obj["challenges"] as? [[String: Any]])?.compactMap { ($0["error"] as? [String: Any])?["detail"] as? String }.first)
                    ?? (obj["error"] as? [String: Any])?["detail"] as? String ?? "invalid"
                throw DNSError(message: "\(what) failed: \(detail)")
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        throw DNSError(message: "\(what) timed out.")
    }

    // MARK: - JWS transport

    private func loadDirectory() async throws {
        let (data, _) = try await URLSession.shared.data(from: directoryURL)
        guard let dir = json(data) else { throw DNSError(message: "Let's Encrypt is unreachable.") }
        directory = dir
    }

    private func url(_ key: String) -> URL { URL(string: directory[key] as? String ?? "")! }

    private func freshNonce() async throws -> String {
        if let n = nonce { nonce = nil; return n }
        var req = URLRequest(url: url("newNonce"))
        req.httpMethod = "HEAD"
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let n = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Replay-Nonce") else {
            throw DNSError(message: "Let's Encrypt: no nonce.")
        }
        return n
    }

    /// payload nil = POST-as-GET.
    private func post(_ url: URL, payload: Any?, useJWK: Bool = false, accept: String? = nil,
                      retry: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var protected: [String: Any] = ["alg": "ES256", "nonce": try await freshNonce(), "url": url.absoluteString]
        if useJWK || kid == nil { protected["jwk"] = jwk } else { protected["kid"] = kid! }
        let p64 = b64u(try JSONSerialization.data(withJSONObject: protected, options: [.withoutEscapingSlashes, .sortedKeys]))
        let body64 = try payload.map { b64u(try JSONSerialization.data(withJSONObject: $0, options: [.withoutEscapingSlashes])) } ?? ""
        let signature = try accountKey.signature(for: Data("\(p64).\(body64)".utf8))
        let jws: [String: String] = ["protected": p64, "payload": body64, "signature": b64u(signature.rawRepresentation)]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/jose+json", forHTTPHeaderField: "Content-Type")
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        req.httpBody = try JSONSerialization.data(withJSONObject: jws)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw DNSError(message: "No reply from Let's Encrypt.") }
        nonce = http.value(forHTTPHeaderField: "Replay-Nonce")

        if http.statusCode >= 400 {
            let problem = json(data)
            let type = problem?["type"] as? String ?? ""
            if retry && type.hasSuffix(":badNonce") {
                return try await post(url, payload: payload, useJWK: useJWK, accept: accept, retry: false)
            }
            throw DNSError(message: "Let's Encrypt: \(problem?["detail"] as? String ?? "HTTP \(http.statusCode)")")
        }
        return (data, http)
    }

    private var jwk: [String: String] {
        let raw = accountKey.publicKey.rawRepresentation   // x || y
        return ["crv": "P-256", "kty": "EC", "x": b64u(raw.prefix(32)), "y": b64u(raw.suffix(32))]
    }

    private var thumbprint: String {
        let k = jwk
        let canonical = "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"\(k["x"]!)\",\"y\":\"\(k["y"]!)\"}"
        return b64u(Data(SHA256.hash(data: Data(canonical.utf8))))
    }

    private func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

func b64u(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// MARK: - CSR (PKCS#10) in hand-written DER

enum DER {
    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
    static func sequence(_ parts: [UInt8]...) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
    static func set(_ parts: [UInt8]...) -> [UInt8] { tlv(0x31, parts.flatMap { $0 }) }
    static func utf8(_ s: String) -> [UInt8] { tlv(0x0C, Array(s.utf8)) }
    static func octets(_ b: [UInt8]) -> [UInt8] { tlv(0x04, b) }
    static func bits(_ b: [UInt8]) -> [UInt8] { tlv(0x03, [0x00] + b) }
    static func oid(_ dotted: String) -> [UInt8] {
        let parts = dotted.split(separator: ".").compactMap { Int($0) }
        var body: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for var v in parts.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(v & 0x7F)]
            v >>= 7
            while v > 0 { chunk.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            body += chunk
        }
        return tlv(0x06, body)
    }
}

enum CSR {
    static func build(names: [String], key: P256.Signing.PrivateKey) throws -> Data {
        let cn = names.first(where: { $0.count <= 64 }) ?? String(names[0].prefix(64))
        let subject = DER.sequence(DER.set(DER.sequence(DER.oid("2.5.4.3"), DER.utf8(cn))))
        let spki = Array(key.publicKey.derRepresentation)
        let generalNames = DER.sequence(names.flatMap { DER.tlv(0x82, Array($0.utf8)) })
        let sanExtension = DER.sequence(DER.oid("2.5.29.17"), DER.octets(generalNames))
        let extensionRequest = DER.sequence(DER.oid("1.2.840.113549.1.9.14"), DER.set(DER.sequence(sanExtension)))
        let attributes = DER.tlv(0xA0, extensionRequest)
        let info = DER.sequence([0x02, 0x01, 0x00], subject, spki, attributes)
        let signature = try key.signature(for: Data(info)).derRepresentation
        let csr = DER.sequence(info, DER.sequence(DER.oid("1.2.840.10045.4.3.2")), DER.bits(Array(signature)))
        return Data(csr)
    }
}
