//
//  File.swift
//  
//
//  Created by Elliot Nash on 2/27/22.
//

import Foundation

class Logger {
    // the main log function that sends a log to parent process as an Event.
    // this should be used instead of print, which should never be used.
    static func log(_ msg: String, level: LogLevel = .log) {
        // format logLevel:message:ETX
        print(level.rawValue+":"+msg, terminator: "\u{3}")
    }
    // convinience functions for log levels
    static func debug(_ msg: String) {
        log(msg, level: .debug)
    }
    static func log(_ msg: String) {
        log(msg, level: .log)
    }
    static func warn(_ msg: String) {
        log(msg, level: .warn)
    }
    static func error(_ msg: String) {
        log(msg, level: .error)
    }
}

enum LogLevel: String {
    case debug
    case log
    case warn
    case error
}
