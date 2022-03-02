//
//  main.swift
//  swiftHelper
//
//  Created by Elliot Nash on 11/16/21.
//
import Foundation

// required to get io to work properly.
setbuf(__stdoutp, nil)
if CommandLine.arguments.count > 1 {
    Logger.info("starting socket on " + CommandLine.arguments[1])
    SocketManager.shared.connect(sock: CommandLine.arguments[1])
    Logger.info("socket closed");
} else {
    Logger.error("no sock file provided")
}
