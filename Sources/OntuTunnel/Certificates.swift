import CryptoKit
import Foundation
import Network
import Security

/// The current HTTPS certificate: private key + PEM chain on disk
/// (~/Library/Application Support/OntuTunnel/tls, files readable only by
/// you), loaded into a private keychain for Network.framework.
struct StoredCertificate {
    let names: [String]
    let notAfter: Date
    let keyX963: Data
    let chainPEM: String

    var daysLeft: Int { Int(notAfter.timeIntervalSinceNow / 86400) }

    func covers(_ host: String) -> Bool {
        let h = host.lowercased()
        return names.contains { name in
            if name.hasPrefix("*.") {
                let base = String(name.dropFirst(2))
                guard h.hasSuffix("." + base) else { return false }
                return !h.dropLast(base.count + 1).contains(".")   // one label only
            }
            return name == h
        }
    }
}

enum CertificateStore {
    static var dir: URL {
        let d = ConfigFile.url.deletingLastPathComponent().appendingPathComponent("tls", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return d
    }
    private static var keyFile: URL { dir.appendingPathComponent("key.x963") }
    private static var chainFile: URL { dir.appendingPathComponent("chain.pem") }
    private static var metaFile: URL { dir.appendingPathComponent("meta.json") }

    static func load() -> StoredCertificate? {
        guard let key = try? Data(contentsOf: keyFile),
              let chain = try? String(contentsOf: chainFile, encoding: .utf8),
              let leaf = certificates(fromPEM: chain).first
        else { return nil }
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: metaFile))) as? [String: Any]
        let names = meta?["names"] as? [String] ?? []
        let notAfter = expiry(of: leaf) ?? Date.distantPast
        return StoredCertificate(names: names, notAfter: notAfter, keyX963: key, chainPEM: chain)
    }

    static func save(names: [String], key: P256.Signing.PrivateKey, chainPEM: String) throws -> StoredCertificate {
        let fm = FileManager.default
        try key.x963Representation.write(to: keyFile, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        try chainPEM.write(to: chainFile, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["names": names]).write(to: metaFile, options: .atomic)
        guard let stored = load() else { throw DNSError(message: "Could not read back the saved certificate.") }
        return stored
    }

    static func certificates(fromPEM pem: String) -> [SecCertificate] {
        pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().compactMap { block in
            let b64 = block.components(separatedBy: "-----END CERTIFICATE-----").first?
                .components(separatedBy: .whitespacesAndNewlines).joined() ?? ""
            guard let der = Data(base64Encoded: b64) else { return nil }
            return SecCertificateCreateWithData(nil, der as CFData)
        }
    }

    static func expiry(of cert: SecCertificate) -> Date? {
        let keys = [kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(cert, keys, nil) as? [CFString: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let number = entry[kSecPropertyKeyValue] as? NSNumber
        else { return nil }
        return Date(timeIntervalSinceReferenceDate: number.doubleValue)
    }

    // MARK: - Identity for Network.framework

    /// A fresh file name every load: macOS keeps a deleted keychain open
    /// for the life of the process, so reusing one name fails (-25296).
    private static func newKeychainPath() -> String {
        let fm = FileManager.default
        for old in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where old.hasPrefix("tls") && old.contains(".keychain") {
            try? fm.removeItem(at: dir.appendingPathComponent(old))
        }
        return dir.appendingPathComponent("tls-\(UUID().uuidString.prefix(8)).keychain-db").path
    }

    /// A throwaway keychain recreated on every load, so the login
    /// keychain never fills up and rebuilding the app never prompts.
    static func identity(for cert: StoredCertificate) throws -> sec_identity_t {
        let chain = certificates(fromPEM: cert.chainPEM)
        guard let leaf = chain.first else { throw DNSError(message: "Certificate file is empty.") }

        let password = "ontutunnel-\(ProcessInfo.processInfo.hostName)"
        let keychainPath = newKeychainPath()
        var keychain: SecKeychain?
        let status = SecKeychainCreate(keychainPath, UInt32(password.utf8.count), password, false, nil, &keychain)
        guard status == errSecSuccess, let keychain else {
            throw DNSError(message: "Could not create the TLS keychain (\(status)).")
        }
        var settings = SecKeychainSettings(version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1), lockOnSleep: false,
                                           useLockInterval: false, lockInterval: UInt32(INT_MAX))
        SecKeychainSetSettings(keychain, &settings)   // never auto-lock

        // import key + certificates through the keychain importer (a raw
        // SecKey can't be added to a file keychain directly)
        try importItems(sec1(x963: cert.keyX963), format: .formatOpenSSL, type: .itemTypePrivateKey, into: keychain)
        for c in chain {
            try importItems(SecCertificateCopyData(c) as Data, format: .formatX509Cert, type: .itemTypeCertificate, into: keychain)
        }

        var identity: SecIdentity?
        let status2 = SecIdentityCreateWithCertificate(keychain, leaf, &identity)
        guard status2 == errSecSuccess, let identity, let secIdentity = sec_identity_create_with_certificates(identity, chain as CFArray) else {
            throw DNSError(message: "Could not pair the certificate with its key (\(status2)).")
        }
        return secIdentity
    }

    /// SEC1 "EC PRIVATE KEY" DER from CryptoKit's x963 form (04|X|Y|D).
    private static func sec1(x963: Data) -> Data {
        let bytes = [UInt8](x963)
        let publicPoint = Array(bytes.prefix(65)), d = Array(bytes.suffix(32))
        return Data(DER.sequence([0x02, 0x01, 0x01], DER.octets(d),
                                 DER.tlv(0xA0, DER.oid("1.2.840.10045.3.1.7")),
                                 DER.tlv(0xA1, DER.bits(publicPoint))))
    }

    private static func importItems(_ data: Data, format: SecExternalFormat, type: SecExternalItemType,
                                     into keychain: SecKeychain) throws {
        var format = format
        var itemType = type
        var params = SecItemImportExportKeyParameters()
        params.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
        var items: CFArray?
        let status = SecItemImport(data as CFData, nil, &format, &itemType, [], &params, keychain, &items)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw DNSError(message: "Could not load the certificate into the TLS keychain (\(status)).")
        }
    }
}
