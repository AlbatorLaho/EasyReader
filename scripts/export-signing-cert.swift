#!/usr/bin/env -S swift -suppress-warnings
// Exports one code signing identity (certificate + private key) for the GitHub Actions secrets used by .github/workflows/build.yml:
//   SIGNING_CERT_P12       base64 of the .p12
//   SIGNING_CERT_PASSWORD  its password
// Only the named identity is exported (SecItemExport on that one item; `security export` can only export every identity).
// macOS asks once to allow exporting its private key.
//
// Usage: scripts/export-signing-cert.swift [-h] [-n name] [-k keychain] [-o out.p12]
//   -n  identity name (default: "HawkRaven Code Signing Certificate")
//   -k  keychain to search (default: keychain search list, e.g. login)
//   -o  write the .p12 to a file and print the password, instead of uploading with `gh` or copying to the clipboard

import AppKit
import CryptoKit
import Foundation
import Security

// MARK: - Helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func describe(_ status: OSStatus) -> String {
    (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
}

func sha1(_ certificate: SecCertificate) -> String {
    Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02X", $0) }.joined()
}

@discardableResult
func run(_ arguments: [String], input: Data? = nil) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = stdout
    let stdin = Pipe()
    if input != nil { process.standardInput = stdin }
    do { try process.run() } catch { return (127, "\(error)") }
    if let input {
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
    }
    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, output)
}

/// Prints the header comment.
func usage(_ status: Int32 = 1) -> Never {
    let source = (try? String(contentsOfFile: CommandLine.arguments[0], encoding: .utf8)) ?? ""
    let header = source.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().prefix { $0.hasPrefix("//") }
    print(header.map { $0.dropFirst($0.hasPrefix("// ") ? 3 : 2) }.joined(separator: "\n"))
    exit(status)
}

// MARK: - Arguments

var name = "HawkRaven Code Signing Certificate"
var keychainPath: String?
var outPath: String?
var arguments = CommandLine.arguments.dropFirst().makeIterator()
func value() -> String {
    guard let value = arguments.next() else { usage() }
    return value
}
while let argument = arguments.next() {
    switch argument {
        case "-n": name = value()
        case "-k": keychainPath = value()
        case "-o": outPath = value()
        case "-h": usage(0)
        default: usage()
    }
}

// MARK: - Find the identity

var query: [String: Any] = [
    kSecClass as String: kSecClassIdentity,
    kSecMatchLimit as String: kSecMatchLimitAll,
    kSecReturnRef as String: true,
]
if let keychainPath {
    // Deprecated, but the only way to search one keychain file; doesn't check the file exists.
    var keychain: SecKeychain?
    guard FileManager.default.fileExists(atPath: keychainPath), SecKeychainOpen(keychainPath, &keychain) == errSecSuccess, let keychain else {
        fail("Can't open keychain \(keychainPath)")
    }
    query[kSecMatchSearchList as String] = [keychain]
}

var result: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &result)
guard status == errSecSuccess || status == errSecItemNotFound else { fail("Keychain search failed: \(describe(status))") }

var matches: [String: SecIdentity] = [:]  // by certificate SHA-1 (same identity may be listed more than once)
for identity in (result as? [SecIdentity]) ?? [] {
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
        SecCertificateCopySubjectSummary(certificate) as String? == name
    else { continue }
    matches[sha1(certificate)] = identity
}
guard !matches.isEmpty else { fail("No identity named \"\(name)\" in \(keychainPath ?? "the keychain search list")") }
guard matches.count == 1, let (hash, identity) = matches.first else {
    fail("Several different identities are named \"\(name)\":\n" + matches.keys.sorted().joined(separator: "\n"))
}
print("Exporting \"\(name)\" (\(hash)) - macOS may ask to allow exporting its private key.")

// MARK: - Export

var randomBytes = [UInt8](repeating: 0, count: 18)
guard SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes) == errSecSuccess else { fail("Can't generate password") }
let password = Data(randomBytes).base64EncodedString()

var parameters = SecItemImportExportKeyParameters()
parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
let passphrase = password as CFString
parameters.passphrase = Unmanaged.passUnretained(passphrase as AnyObject)
var exported: CFData?
let exportStatus = withExtendedLifetime(passphrase) {
    SecItemExport(identity, .formatPKCS12, [], &parameters, &exported)
}
guard exportStatus == errSecSuccess, let p12 = exported as Data? else { fail("Export failed: \(describe(exportStatus))") }

// MARK: - Verify (same import CI does, into a throwaway keychain)

/// Returns nil on success, else the import output.
func verify() -> String? {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])) != nil
    else { return "Can't create \(directory.path)" }
    defer { try? FileManager.default.removeItem(at: directory) }
    let p12File = directory.appendingPathComponent("signing.p12").path
    let keychain = directory.appendingPathComponent("verify.keychain-db").path
    guard FileManager.default.createFile(atPath: p12File, contents: p12, attributes: [.posixPermissions: 0o600]) else { return "Can't write \(p12File)" }
    run(["security", "create-keychain", "-p", "verify", keychain])
    defer { run(["security", "delete-keychain", keychain]) }
    let imported = run(["security", "import", p12File, "-k", keychain, "-P", password])
    return imported.status == 0 && run(["security", "find-identity", keychain]).output.contains(hash) ? nil : imported.output
}
if let error = verify() { fail("Verification failed: exported .p12 doesn't import as \(hash)\n\(error)") }
print("Verified exported identity.")

// MARK: - Deliver

if let outPath {
    guard FileManager.default.createFile(atPath: outPath, contents: p12, attributes: [.posixPermissions: 0o600]) else {
        fail("Can't write \(outPath)")
    }
    print("Wrote \(outPath)")
    print("Password: \(password)")
    print("Secrets: SIGNING_CERT_P12 = $(base64 -i \(outPath)), SIGNING_CERT_PASSWORD = the password. Delete \(outPath) afterwards.")
    exit(0)
}

func ask(_ prompt: String) -> String {
    print(prompt, terminator: "")
    fflush(stdout)
    return readLine() ?? ""
}

if run(["gh", "auth", "status"]).status == 0,
    ["y", "Y"].contains(ask("Upload SIGNING_CERT_P12 and SIGNING_CERT_PASSWORD to this repo with gh? [y/N] "))
{
    let p12Upload = run(["gh", "secret", "set", "SIGNING_CERT_P12"], input: Data(p12.base64EncodedString().utf8))
    let passwordUpload = run(["gh", "secret", "set", "SIGNING_CERT_PASSWORD"], input: Data(password.utf8))
    guard p12Upload.status == 0, passwordUpload.status == 0 else { fail("gh upload failed:\n\(p12Upload.output)\(passwordUpload.output)") }
    print("Secrets uploaded.")
    exit(0)
}

let pasteboard = NSPasteboard.general
print("\nAdd these at GitHub: repo Settings > Secrets and variables > Actions > New repository secret.")
pasteboard.clearContents()
pasteboard.setString(p12.base64EncodedString(), forType: .string)
_ = ask("1/2 SIGNING_CERT_P12 copied to clipboard. Paste it, then press Enter... ")
pasteboard.clearContents()
pasteboard.setString(password, forType: .string)
_ = ask("2/2 SIGNING_CERT_PASSWORD copied to clipboard. Paste it, then press Enter... ")
pasteboard.clearContents()
print("Clipboard cleared. Done.")
