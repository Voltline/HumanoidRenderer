//
//  LiveKitToken.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2026/1/10.
//

import Foundation
import CryptoKit

enum LiveKitToken {
    struct Grants: Encodable {
        var roomJoin: Bool = true
        var room: String
    }
    
    struct Payload: Encodable {
        var exp: Int
        var nbf: Int
        var iss: String
        var sub: String
        var name: String
        var identity: String
        var video: Grants
    }
    
    static func make(
        apiKey: String,
        apiSecret: String,
        room: String,
        identity: String,
        name: String? = nil,
        ttlSeconds: Int = 60 * 60
    ) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: String] = [
            "alg": "HS256",
            "typ": "JWT"
        ]
        
        let payload = Payload(
            exp: now + ttlSeconds,
            nbf: now,
            iss: apiKey,
            sub: identity,
            name: name ?? identity,
            identity: identity,
            video: Grants(roomJoin: true, room: room)
        )
        let headerData = try JSONEncoder().encode(header)
        let payloadData = try JSONEncoder().encode(payload)
        
        let headerB64 = base64url(headerData)
        let payloadB64 = base64url(payloadData)
        let signingInput = "\(headerB64).\(payloadB64)"
        
        let key = SymmetricKey(data: Data(apiSecret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: key)
        let sigB64 = base64url(Data(signature))
        
        return "\(signingInput).\(sigB64)"
    }
    
    private static func base64url(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
