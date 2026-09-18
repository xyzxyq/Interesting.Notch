import Foundation
import CryptoKit

// Verify against the public key shipped in the app, independently of the signing Keychain.
let arguments = CommandLine.arguments
guard arguments.count == 4,
       let signature = Data(base64Encoded: arguments[2]),
       let keyData = Data(base64Encoded: arguments[3]) else {
    fatalError("Usage: VerifyUpdate.swift <archive> <signature> <public-key>")
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: data) else {
    fputs("Update signature rejected\n", stderr)
    exit(1)
}
print("Update signature verified against the app's public key")
