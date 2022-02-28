//
//  main.swift
//  swiftHelper
//
//  Created by Elliot Nash on 11/16/21.
//
import Foundation

// required to get io to work properly.
setbuf(__stdoutp, nil)

EventManager.shared.run()
