//
//  Deserializers.swift
//  swiftHelper
//
//  Created by Elliot Nash on 11/16/21.
//

import Foundation


func isScalar(value: Any, allowSequences: Bool) -> Bool {
    if (allowSequences) {
        return value is NSString || value is NSNumber || value is NSNull || value is NSArray || value is NSDictionary
    } else {
        return value is NSString || value is NSNumber || value is NSNull
    }
}


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
            // but it doesn't seem high priority and is usually just related
            // to a message including a date, which could be implemented without
            // the extra data from the attributedBody field.
            // because we're effectively removing the attribute value here, this can
            // lead to multiple keys over adjacent ranges that have the same value
            var shouldAdd = isScalar(value: attr.value, allowSequences: true)
            if (shouldAdd && attr.value is NSArray) {
                for subItem in (attr.value as! NSArray) {
                    if (!isScalar(value: subItem, allowSequences: false)) {
                        shouldAdd = false
                        break
                    }
                }
                runAttributes[attr.key] = attr.value
            } else if (shouldAdd && attr.value is NSArray) {
                for (_, subItem) in (attr.value as! NSDictionary).enumerated() {
                    if (!isScalar(value: subItem.value, allowSequences: false)) {
                        shouldAdd = false
                        break
                    }
                }
            }

            if (shouldAdd) {
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
