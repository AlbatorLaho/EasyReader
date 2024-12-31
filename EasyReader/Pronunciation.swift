//
//  Pronunciation.swift
//  EasyReader
//
//  Created by Ewalk on 24/12/22.
//

import Foundation
import Defaults

//extension Defaults.Keys {
//    static let useVoiceOverPronunciations = Key<Bool>("useVoiceOverPronunciations", default: false)
//    static let pronunciations = Key<[Pronunciation]>("pronunciations", default: [])
//}

//struct Pronunciation: Identifiable, Codable, Defaults.Serializable {
//    let id = UUID()
struct Pronunciation: Codable, Defaults.Serializable {
    var search: String
    var replace: String
    var domain: String?
//    var options: String.CompareOptions = [.caseInsensitive]
    var ignoreCase: Bool = true
//    var regex: Bool = false
    var enabled: Bool = true
    var options: String.CompareOptions {
        ignoreCase ? [.caseInsensitive] : []
    }
}

//extension String.CompareOptions: Codable {
//    public init(from decoder: Decoder) throws {
//        let container = try decoder.singleValueContainer()
//        let rawValue = try container.decode(RawValue.self)
//        self.init(rawValue: rawValue)
//    }
//
//    public func encode(to encoder: Encoder) throws {
//        var container = encoder.singleValueContainer()
//        try container.encode(rawValue)
//    }
//}

//TODO: add easier filters for domain &c.?
//struct PronunciationManager {}
extension Pronunciation {
    static func getVoiceOverPronunciations() -> [Pronunciation]? {
        return UserDefaults.standard.persistentDomain(forName: "com.apple.VoiceOver4/default")?.compactMap({ key, value in
//            NOTE: can't get default pronunciations because they use SCRSubTextKey instead of SCRSubText
//            NOTE: SCRIgnoreCase starts as a string, but is converted to a bool after you change its value in VoiceOver Utility...
            guard key.starts(with: "custom.pronunciation"),
//                  let pronunciation = value as? [String: String],
                  let pronunciation = value as? [String: Any],
                  let search = pronunciation["SCRSearchText"] as? String,
                  let replace = pronunciation["SCRSubText"] as? String
            else { return nil }
            let domain = pronunciation["SCRDomainIdentifier"] as? String
//            let ignoreCase = pronunciation["SCRIgnoreCase"] as? Bool ?? (pronunciation["SCRIgnoreCase"] as? String != "0")
//            let enabled = pronunciation["SCREnabled"] as? Bool ?? (pronunciation["SCREnabled"] as? String != "0")
//            print(ignoreCase)
//            print(enabled)
            let ignoreCase = pronunciation["SCRIgnoreCase"]
            let enabled = pronunciation["SCREnabled"]
            return Pronunciation(
                search: search,
                replace: replace,
                domain: domain == "SCRAnyApplication" ? nil : domain,
                ignoreCase: ignoreCase as? Bool ?? (ignoreCase as? String != "0"),
                enabled: enabled as? Bool ?? (enabled as? String != "0")
//                domain: pronunciation["SCRDomainIdentifier"],
//                ignoreCase: pronunciation["SCRIgnoreCase"] == "1",
//                enabled: pronunciation["SCREnabled"] == "1"
            )
        })
    }
}
