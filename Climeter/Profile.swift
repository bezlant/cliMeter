import Foundation

enum CredentialSource: String, Codable {
    case cliSynced   // mirrors Claude Code; read-only, never refreshed/written
    case selfOwned   // manually pasted session key; Climeter owns the token
}

struct Profile: Codable, Identifiable {
    let id: UUID
    var name: String
    var credentialSource: CredentialSource

    init(id: UUID = UUID(), name: String, credentialSource: CredentialSource = .cliSynced) {
        self.id = id
        self.name = name
        self.credentialSource = credentialSource
    }

    // Custom decode so profiles persisted before this field default to .cliSynced.
    // CodingKeys + encode(to:) remain auto-synthesized; do NOT add a manual CodingKeys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        credentialSource = try c.decodeIfPresent(CredentialSource.self, forKey: .credentialSource) ?? .cliSynced
    }
}
