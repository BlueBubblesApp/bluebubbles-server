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
    // we're going to enumarate through each attribute, and store the attribute
    // value along with position in the corsponding run
    var attributeRuns: [[String: Any]] = []
    attrStr!.enumerateAttributes(in: NSMakeRange(0, attrStr!.length), options: NSAttributedString.EnumerationOptions(), using: {attrs,range,_ in
        // get the location of the attribute
        let rangeArray = [range.location, range.length]
        // get the actual attributes and enumerate
        var runAttributes: [NSAttributedString.Key: Any] = [:]
        for (_, attr) in attrs.enumerated() {
            // now we need to check if the type is actually serializible
            // ie trying to serialize NSData will screw stuff up
            // I'm pretty sure we can parse this data if we want later,
            // but it doesn't seem important and is usually just related
            // to the date/timestamp of a tapback
            if (!(attr.value is NSData)) {
                runAttributes[attr.key] = attr.value
            }
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
