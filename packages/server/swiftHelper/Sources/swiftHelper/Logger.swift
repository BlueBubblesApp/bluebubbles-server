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
    static func log(_ msg: String, level: LogLevel = .info) {
        print(level.rawValue+":"+msg)
    }
    // convinience functions for log levels
    static func debug(_ msg: String) {
        log(msg, level: .debug)
    }
    static func info(_ msg: String) {
        log(msg, level: .info)
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
    case info
    case warn
    case error
}
