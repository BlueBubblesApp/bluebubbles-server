//
//  SocketManager.swift
//  swiftHelper
//
//  Created by Elliot Nash on 11/16/21.
//

import Foundation
import Socket

// The main event loop. Listens for socket event, then parses
// new event, then dispatches that event's handler.
class SocketManager {
    static let shared = SocketManager()
    var sock: Socket? = nil
    func connect(sock: String) {
        while true {
            do {
                try self.sock = Socket.create(family: Socket.ProtocolFamily.unix, proto: Socket.SocketProtocol.unix)
                try self.sock?.connect(to: sock)
                Logger.debug("connected to socket")
                event()
                Logger.debug("socket disconnected")
            } catch let error {
                guard let socketError = error as? Socket.Error else {
                    Logger.error("unexpected error...\n \(error)")
                    return
                }
                Logger.error("error reported:\n \(socketError.description)")
            }
            Logger.debug("attempting reconnect in 5 seconds")
            sleep(5)
        }
    }
    private func event() {
        var readData = Data(capacity: 12288)
        while true {
            do {
                readData.removeAll()
                let bytesRead = try sock?.read(into: &readData)
                // if data is empty we should force a reconnnect
                if (readData.isEmpty) {
                    break
                }
                guard let msg = Event.fromBytes(bytes: readData, bytesRead: bytesRead!) else {
                    Logger.warn("error decoding")
                    continue
                }
                Logger.debug("Recieved socket message: "+msg.name+":"+msg.uuid)
                try sock?.write(from: msg.handleMessage()!.toBytes())
            } catch let error {
                guard let socketError = error as? Socket.Error else {
                    Logger.error("Unexpected error by connection at \(sock?.remotePath ?? "null")...")
                    return
                }
                Logger.error("Error reported by connection at \(sock?.remotePath ?? "null"):\n \(socketError.description)")
            }
        }
    }
}
