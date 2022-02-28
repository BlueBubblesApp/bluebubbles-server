//
//  Deserializers.swift
//  swiftHelper
//
//  Created by Elliot Nash on 11/16/21.
//

import Foundation

func deserializeAttributedBody(data: Data) -> Data {
    let typedStreamUnarchiver = NSUnarchiver(forReadingWith:data)
    let attrStr = typedStreamUnarchiver!.decodeObject() as! NSAttributedString?
    var attributeRuns: [[String: Any]] = []
    attrStr!.enumerateAttributes(in: NSMakeRange(0, attrStr!.length), options: NSAttributedString.EnumerationOptions(), using: {attrs,range,_ in
        let rangeArray = [range.location, range.length]
        var runAttributes: [NSAttributedString.Key: Any] = [:]
        for (_, attr) in attrs.enumerated() {
            runAttributes[attr.key] = attr.value
        }
        if (runAttributes.count == 0) {return}
        attributeRuns.append([
            "range": rangeArray,
            "attributes": runAttributes
        ])
    })

    let jsonOutput: [String: Any] = [
        "string": attrStr!.string,
        "runs": attributeRuns
    ]
    let jsonData = try? JSONSerialization.data(withJSONObject: jsonOutput, options: JSONSerialization.WritingOptions())
    return jsonData!
}
