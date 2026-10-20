import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Update verification failed: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("Usage: swift scripts/verify-update.swift <appcast> <Info.plist> <archive>")
}

do {
    let feedURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let plistURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let archiveURL = URL(fileURLWithPath: CommandLine.arguments[3])
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
    guard let version = plist?["CFBundleShortVersionString"] as? String,
          let encodedKey = plist?["SUPublicEDKey"] as? String,
          let keyData = Data(base64Encoded: encodedKey) else {
        fail("Info.plist must contain the release version and Sparkle public key.")
    }
    let namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    let feed = try XMLDocument(contentsOf: feedURL)
    let items = try feed.nodes(forXPath: "/rss/channel/item").compactMap { $0 as? XMLElement }.filter {
        $0.elements(forLocalName: "shortVersionString", uri: namespace).first?.stringValue == version
    }
    guard items.count == 1,
          let encodedSignature = items[0].elements(forName: "enclosure").first?
            .attribute(forLocalName: "edSignature", uri: namespace)?.stringValue,
          let signature = Data(base64Encoded: encodedSignature), signature.count == 64 else {
        fail("The feed must contain one signed item for \(version).")
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    guard publicKey.isValidSignature(signature, for: try Data(contentsOf: archiveURL)) else {
        fail("The archive signature does not match the Sparkle public key in Info.plist.")
    }
    print("Verified update signature for \(version).")
} catch {
    fail(error.localizedDescription)
}
