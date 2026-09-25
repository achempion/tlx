import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

struct SSH {
    let host: String
    let port: Int
    let privateKey: Data

    struct Output {
        var stdout = Data()
        var stderr = Data()
        var exitStatus = 0
    }

    func run(_ command: String, stdin: Data = Data()) async throws -> Output {
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        let firstError = FirstError()
        let connection = try await ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: KeyAuthentication(NIOSSHPrivateKey(ed25519Key: signingKey)),
                            serverAuthDelegate: PinnedHostKey("\(host):\(port)"))),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandlers(ssh, firstError)
                }
            }
            .connect(host: host, port: port).get()
        let deadline = connection.eventLoop.scheduleTask(in: .seconds(90)) { connection.close(promise: nil) }
        defer {
            deadline.cancel()
            connection.close(promise: nil)
        }

        let collector = SessionCollector(command: command, stdin: stdin)
        do {
            let session = try await connection.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                let opened = connection.eventLoop.makePromise(of: Channel.self)
                ssh.createChannel(opened) { session, _ in
                    session.eventLoop.makeCompletedFuture {
                        try session.pipeline.syncOperations.addHandler(collector)
                    }
                }
                return opened.futureResult
            }.get()
            try await session.closeFuture.get()
        } catch {
            throw firstError.error ?? error
        }
        guard collector.exited else {
            throw firstError.error ?? SSHError.disconnected
        }
        return collector.result
    }
}

enum SSHError: LocalizedError {
    case hostKeyChanged
    case authenticationFailed
    case disconnected

    var errorDescription: String? {
        switch self {
        case .hostKeyChanged: return "the host key changed"
        case .authenticationFailed: return "the key was not accepted"
        case .disconnected: return "the connection was closed"
        }
    }
}

private final class KeyAuthentication: NIOSSHClientUserAuthenticationDelegate {
    let key: NIOSSHPrivateKey
    var offered = false

    init(_ key: NIOSSHPrivateKey) {
        self.key = key
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else {
            return nextChallengePromise.fail(SSHError.authenticationFailed)
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: "tlx", serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}

private final class PinnedHostKey: NIOSSHClientServerAuthenticationDelegate {
    let name: String

    init(_ name: String) {
        self.name = name
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey)
        guard let pinned = UserDefaults.standard.string(forKey: "host_key:\(name)") else {
            UserDefaults.standard.set(presented, forKey: "host_key:\(name)")
            return validationCompletePromise.succeed(())
        }
        if pinned == presented {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(SSHError.hostKeyChanged)
        }
    }
}

private final class FirstError: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    var error: Error?

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if self.error == nil {
            self.error = error
        }
        context.close(promise: nil)
    }
}

private final class SessionCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    let command: String
    let stdin: Data
    var result = SSH.Output()
    var exited = false

    init(command: String, stdin: Data) {
        self.command = command
        self.stdin = stdin
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)
        context.triggerUserOutboundEvent(exec, promise: nil)
        if !stdin.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: stdin.count)
            buffer.writeBytes(stdin)
            context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
        }
        context.close(mode: .output, promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let chunk = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = chunk.data else {
            return
        }
        if chunk.type == .stdErr {
            result.stderr.append(contentsOf: buffer.readableBytesView)
        } else {
            result.stdout.append(contentsOf: buffer.readableBytesView)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            result.exitStatus = status.exitStatus
            exited = true
        }
        context.fireUserInboundEventTriggered(event)
    }
}
