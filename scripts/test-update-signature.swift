import CryptoKit
import Foundation

let root = FileManager.default.temporaryDirectory.appendingPathComponent("BetterMeetingSignature-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let verifier = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("verify-update.swift")
let binary = root.appendingPathComponent("verify-update")

func run(_ arguments: [String]) throws -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

let (compiled, compilerOutput) = try run(["swiftc", "-module-cache-path", root.appendingPathComponent("module-cache").path,
                                        verifier.path, "-o", binary.path])
guard compiled == 0 else {
    FileHandle.standardError.write(Data(compilerOutput.utf8))
    exit(1)
}
let archive = Data("Disposable update archive".utf8)
let key = Curve25519.Signing.PrivateKey()
let signature = try key.signature(for: archive).base64EncodedString()
let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
let wrongKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
let cases: [(String, String?, String, Data, String?)] = [
    ("valid", signature, publicKey, archive, nil),
    ("missing signature", nil, publicKey, archive, "one signed item"),
    ("malformed signature", "bad", publicKey, archive, "one signed item"),
    ("wrong public key", signature, wrongKey, archive, "does not match"),
    ("modified archive", signature, publicKey, archive + Data("changed".utf8), "does not match")
]
for (name, signature, publicKey, bytes, error) in cases {
    let plist: [String: String] = ["CFBundleShortVersionString": "1.0.0", "SUPublicEDKey": publicKey]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: root.appendingPathComponent("Info.plist"))
    let attribute = signature.map { "sparkle:edSignature=\"\($0)\"" } ?? ""
    try Data("""
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
    <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString><enclosure \(attribute)/>
    </item></channel></rss>
    """.utf8).write(to: root.appendingPathComponent("appcast.xml"))
    try bytes.write(to: root.appendingPathComponent("update.zip"))
    let (status, output) = try run([binary.path, root.appendingPathComponent("appcast.xml").path,
                                  root.appendingPathComponent("Info.plist").path, root.appendingPathComponent("update.zip").path])
    guard error == nil ? status == 0 : status != 0 && output.contains(error!) else {
        FileHandle.standardError.write(Data("\(name): \(output)".utf8))
        exit(1)
    }
    print("Passed: \(name)")
}
