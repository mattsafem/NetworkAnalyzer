//
//  main.swift
//  NetworkAnalyzerExtension
//
//  Created by s on 12/30/25.
//

import Foundation
import NetworkExtension
import os.log

let log = Logger(subsystem: "com.safeme.networkanalyzer.networkanalyzerextension", category: "main")

autoreleasepool {
    log.info("NetworkAnalyzerExtension starting...")
    NEProvider.startSystemExtensionMode()
}

dispatchMain()
