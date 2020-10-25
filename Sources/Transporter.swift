//
//  Transporter.swift
//  atlantis-iOS
//
//  Created by Nghia Tran on 10/23/20.
//  Copyright © 2020 Proxyman. All rights reserved.
//

import Foundation

protocol Transporter {

    func start(_ config: Configuration)
    func stop()
    func send(package: Serializable)
}

protocol Serializable {

    func toData() -> Data?
}

final class NetServiceTransport: NSObject {

    private struct Constants {
        static let netServiceType = "_Proxyman._tcp"
        static let netServiceDomain = ""
    }

    // MARK: - Variabls

    private let serviceBrowser: NetServiceBrowser
    private var services: [NetService] = []
    private let queue = DispatchQueue(label: "com.proxyman.atlantis.netservices") // Serial on purpose
    private let session: URLSession
    private var task: URLSessionStreamTask?
    private var pendingPackages: [Serializable] = []

    // MARK: - Public

    override init() {
        self.serviceBrowser = NetServiceBrowser()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
        super.init()
        serviceBrowser.delegate = self
    }
}

// MARK: - Transporter

extension NetServiceTransport: Transporter {

    func start(_ config: Configuration) {
        // Reset all current connections if need
        stop()

        // Safe thread
        queue.sync {
            // Create a first connection message
            // which contains the project, device metadata
            let connectionMessage = Message.buildConnectionMessage(id: config.id, item: ConnectionPackage(config: config))

            // Add to top of the pending list, when the connection is available, it will send firstly
            pendingPackages.insert(connectionMessage, at: 0)
        }

        // Start searching
        // Have to run on MainThread, otherwise, the service will stop for some reason
        serviceBrowser.searchForServices(ofType: Constants.netServiceType, inDomain: Constants.netServiceDomain)
    }

    func stop() {
        queue.sync {
            services.forEach { $0.stop() }
            services.removeAll()
            serviceBrowser.stop()
        }
    }

    func send(package: Serializable) {
        queue.async {[weak self] in
            guard let strongSelf = self else { return }
            print("Send package = \(package)")
            guard let task = strongSelf.task, task.state == .running else {
                // It means the connection is not ready
                // We add the package to the pending list
                print("Add package to the pending list...")
                strongSelf.pendingPackages.append(package)
                return
            }

            // Flush all pending data if need
            strongSelf.flushAllPendingIfNeed()

            // Send the main one
            strongSelf.stream(package: package)
        }
    }

    private func stream(package: Serializable) {
        guard let data = package.toData() else { return }

        // Compose a message
        // [1]: the length of the second message. We reserver 8 bytes to store this data
        // [2]: The actual message

        let buffer = NSMutableData()
        var lengthPackage = data.count
        buffer.append(&lengthPackage, length: Int(MemoryLayout<UInt64>.stride))
        buffer.append([UInt8](data), length: data.count)

        print("------ Write length message = \(data.count)")

        // Write data
        task?.write(buffer as Data, timeout: 5) { (error) in
            if let error = error {
                print(error)
            }
        }
    }

    private func flushAllPendingIfNeed() {
        guard !pendingPackages.isEmpty else { return }
        for package in pendingPackages {
            stream(package: package)
        }
        pendingPackages.removeAll()
    }
}

// MARK: - Private

extension NetServiceTransport {

    private func connectToService(_ service: NetService) {
        print("Connect to server address count = \(service.addresses?.count ?? 0)")
        // Stop previous connection if need
        if let task = task {
            task.closeWrite()
        }

        // Create a newone
        task = session.streamTask(with: service)
        task?.resume()

        // All pending
        queue.async {[weak self] in
            self?.flushAllPendingIfNeed()
        }
    }
}

// MARK: - NetServiceBrowserDelegate

extension NetServiceTransport: NetServiceBrowserDelegate {

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        print("didFind service \(service)")
        queue.async {[weak self] in
            guard let strongSelf = self else { return }
            strongSelf.services.append(service)
            service.delegate = strongSelf
            service.resolve(withTimeout: 30)
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        print("didRemove service \(service)")
        queue.async {[weak self] in
            guard let strongSelf = self else { return }
            if let index = strongSelf.services.firstIndex(where: { $0 === service }) {
                strongSelf.services.remove(at: index)
            }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        print("[Atlantis][ERROR] didNotSearch \(errorDict)")
    }

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        print("netServiceBrowserWillSearch")
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        print("netServiceBrowserDidStopSearch")
    }
}

// MARK: - NetServiceDelegate

extension NetServiceTransport: NetServiceDelegate {

    func netServiceDidResolveAddress(_ sender: NetService) {
        print("netServiceDidResolveAddress")
        connectToService(sender)
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        print("[Atlantis][ERROR] didNotPublish \(errorDict)")
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        print("[Atlantis][ERROR] didNotResolve \(errorDict)")
    }
}
