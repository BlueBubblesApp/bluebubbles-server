//
//  SocketManager.swift
//  swiftHelper
//
//  Created by Elliot Nash on 11/16/21.
//

import Foundation
import Socket

// The main event loop. Listens for stdin, and tries to parse
// new input as an Event, then dispatches that event's handler.
class EventManager {
    static let shared = EventManager()
    // starts the event loop
    func run() {
        Logger.info("Starting event loop")
        while true {
            let data = FileHandle.standardInput.availableData
            guard let event = Event.fromBytes(bytes: data) else {
                Logger.error("failed to parse event: "+String(data: data, encoding: .ascii)!)
                continue
            }
            Logger.debug("Recieved event: "+event.name+":"+event.uuid)
            // we recieved socket event, now should dispatch to handler
            event.handleMessage()!.send()
        }
    }
}
