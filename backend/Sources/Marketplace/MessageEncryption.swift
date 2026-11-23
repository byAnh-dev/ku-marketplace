
import Foundation
import Crypto
import Vapor

enum MessageEncryption {
    private static let prefix = "enc:v1:"

    private static func key() throws -> SymmetricKey {
        guard let encoded = Environment.get(
            "PRIVATE_MESSAGE_KEY_BASE64"
        ),
        let data = Data(base64Encoded: encoded),
        data.count == 32 else {
            throw Abort(
                .internalServerError,
                reason: "Private message encryption is not configured."
            )
        }

        return SymmetricKey(data: data)
    }

    static func encrypt(_ plaintext: String) throws -> String {
        let secret = try key()

        let sealed = try AES.GCM.seal(
            Data(plaintext.utf8),
            using: secret
        )

        guard let combined = sealed.combined else {
            throw Abort(.internalServerError)
        }

        return prefix + combined.base64EncodedString()
    }

    static func decrypt(_ stored: String) throws -> String {
        guard stored.hasPrefix(prefix) else {
            return stored
        }

        let payload = String(
            stored.dropFirst(prefix.count)
        )

        guard let combined = Data(
            base64Encoded: payload
        ) else {
            throw Abort(
                .internalServerError,
                reason: "Stored encrypted message is invalid."
            )
        }

        let box = try AES.GCM.SealedBox(
            combined: combined
        )

        let plaintext = try AES.GCM.open(
            box,
            using: key()
        )

        guard let text = String(
            data: plaintext,
            encoding: .utf8
        ) else {
            throw Abort(
                .internalServerError,
                reason: "Stored encrypted message is invalid."
            )
        }

        return text
    }

    static func isEncrypted(_ stored: String) -> Bool {
        stored.hasPrefix(prefix)
    }
}
