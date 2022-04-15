//
//  SocketMessage.swift
//  swiftHelper
//
//  Created by Elliot Nash on 11/16/21.
//

import Foundation

let START_OF_TEXT: UInt8 = 0x02
let END_OF_TEXT: UInt8 = 0x03
let END_OF_TRANSMISSION: UInt8 = 0x04

class Event {
    let name: String
    let data: Data
    let uuid: String
    convenience init(event: String, data: Data) {
        self.init(event: event, uuid: UUID().uuidString, data: data)
    }
    init(event: String, uuid: String, data: Data) {
        self.name = event
        self.data = data
        self.uuid = uuid
    }
    static func fromBytes(bytes: Data, bytesRead: Int) -> Event? {
        guard let eventStart = bytes.firstIndex(of: START_OF_TEXT) else {return nil}
        guard let eventEnd = bytes.firstIndex(of: END_OF_TEXT) else {return nil}
        let eventData = bytes.subdata(in: eventStart+1 ..< eventEnd)
        guard let event = String(data: eventData, encoding: .ascii) else {return nil}
        
        let remain = bytes.subdata(in: eventEnd+1 ..< bytesRead)
                
        guard let uuidStart = remain.firstIndex(of: START_OF_TEXT) else {return nil}
        guard let uuidEnd = remain.firstIndex(of: END_OF_TEXT) else {return nil}
        let uuidData = remain.subdata(in: uuidStart+1 ..< uuidEnd)
        guard let uuid = String(data: uuidData, encoding: .ascii) else {return nil}
        let data = remain.subdata(in: uuidEnd+1 ..< remain.count-1)
        return Event(event: event, uuid: uuid, data: data)
    }
    func toBytes() -> Data {
        var data = Data([START_OF_TEXT])
        data.append(name.data(using: .ascii)!)
        data.append(Data([END_OF_TEXT, START_OF_TEXT]))
        data.append(uuid.data(using: .ascii)!)
        data.append(Data([END_OF_TEXT]))
        data.append(self.data)
        data.append(Data([END_OF_TRANSMISSION]))
        return data
    }
    func handleMessage() -> Event? {
        var data: Data? = nil
        if (name == "deserializeAttributedBody") {
            data = deserializeAttributedBody(data: self.data)
        }
        guard let data = data else {return nil}
        return Event(event: name, uuid: self.uuid, data: data)
    }
}
