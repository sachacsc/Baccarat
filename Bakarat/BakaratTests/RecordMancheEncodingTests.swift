//
//  RecordMancheEncodingTests.swift
//  BakaratTests
//
//  Régression : le bug récurrent où une struct passée à `client.rpc(...)`
//  avec un Optional<UUID> nil voyait sa clé OMISE du JSON par le JSONEncoder
//  par défaut, ce qui fait que PostgREST ne matche plus la signature à 12
//  paramètres et renvoie PGRST202 "function not found in schema cache".
//
//  Pattern correct (utilisé dans OnlineGameService.RecordMancheParams ET
//  CounterCloudSync.RecordMancheParams) : custom `encode(to:)` qui appelle
//  `c.encode(opt, forKey: ...)` (PAS `encodeIfPresent`) — l'Optional<T>
//  écrit JSON null explicite plutôt que de skip la clé.
//

import Testing
import Foundation

struct RecordMancheEncodingTests {

    /// Sanity check : le comportement par défaut de JSONEncoder OMET les
    /// optionals nil. C'est précisément ce qu'on veut éviter.
    @Test func defaultEncoderOmitsNilOptionals() throws {
        struct Naive: Encodable {
            let id: UUID?
            let name: String
        }
        let json = try JSONEncoder().encode(Naive(id: nil, name: "x"))
        let str = String(data: json, encoding: .utf8) ?? ""
        #expect(!str.contains("\"id\""), "JSONEncoder default OMET les nil — confirme la trap")
        #expect(str.contains("\"name\":\"x\""))
    }

    /// Le pattern qu'on utilise : custom encode(to:) qui force l'écriture
    /// explicite de null pour les clés Optional. Vérifie que la clé est
    /// présente avec la valeur JSON null.
    @Test func customEncodeWritesExplicitNull() throws {
        struct Safe: Encodable {
            let id: UUID?
            let name: String
            enum CodingKeys: String, CodingKey { case id, name }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                try c.encode(name, forKey: .name)
            }
        }
        let json = try JSONEncoder().encode(Safe(id: nil, name: "x"))
        let str = String(data: json, encoding: .utf8) ?? ""
        #expect(str.contains("\"id\":null"), "La clé id doit apparaître avec JSON null explicite")
        #expect(str.contains("\"name\":\"x\""))
    }

    /// Avec une valeur non-nulle, le pattern doit toujours marcher.
    @Test func customEncodeWithValuePresent() throws {
        struct Safe: Encodable {
            let id: UUID?
            enum CodingKeys: String, CodingKey { case id }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
            }
        }
        let uuid = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let json = try JSONEncoder().encode(Safe(id: uuid))
        let str = String(data: json, encoding: .utf8) ?? ""
        #expect(str.contains("12345678-1234-1234-1234-123456789ABC"))
    }
}
