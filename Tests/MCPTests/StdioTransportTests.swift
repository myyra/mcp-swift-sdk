import Foundation
import Testing

@testable import MCP

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

@Suite("Stdio Transport Tests")
struct StdioTransportTests {
    @Test("Repeated initialization replaces client state over stdio", .timeLimit(.minutes(1)))
    func repeatedInitialization() async throws {
        let (serverInput, clientOutput) = try FileDescriptor.pipe()
        let (clientInput, serverOutput) = try FileDescriptor.pipe()
        defer {
            try? serverInput.close()
            try? clientOutput.close()
            try? clientInput.close()
            try? serverOutput.close()
        }

        let serverTransport = StdioTransport(input: serverInput, output: serverOutput)
        let clientTransport = StdioTransport(input: clientInput, output: clientOutput)
        let server = Server(name: "TestServer", version: "1.0", configuration: .strict)

        do {
            try await confirmation("Initialization hook runs for every request", expectedCount: 4) {
                hookCalled in
                try await server.start(transport: serverTransport) { info, capabilities in
                    hookCalled()
                    #expect(info.name == "Client\(info.version)")
                    #expect((capabilities.roots != nil) == (info.version == "1"))
                    if info.version == "2" {
                        throw MCPError.invalidRequest("Client not allowed")
                    }
                }
                try await clientTransport.connect()
                var responses = await clientTransport.receive().makeAsyncIterator()

                for index in 0..<4 {
                    let requestedVersion = index == 0 ? Version.latest : "2024-11-05"
                    let request = Initialize.request(
                        .init(
                            protocolVersion: requestedVersion,
                            capabilities: .init(roots: index == 1 ? .init() : nil),
                            clientInfo: .init(name: "Client\(index)", version: "\(index)")
                        ))
                    try await clientTransport.send(JSONEncoder().encode(request))
                    let data = try #require(try await responses.next())
                    let response = try JSONDecoder().decode(Response<Initialize>.self, from: data)
                    #expect(response.id == request.id)

                    if index == 2 {
                        #expect(throws: MCPError.invalidRequest("Client not allowed")) {
                            try response.result.get()
                        }
                    } else {
                        let result = try response.result.get()
                        #expect(result.protocolVersion == requestedVersion)
                        #expect(result.serverInfo.name == "TestServer")
                    }

                    if index == 1 || index == 2 {
                        let rootsTask = Task { try await server.listRoots() }
                        let rootsData = try #require(try await responses.next())
                        let rootsRequest = try JSONDecoder().decode(
                            Request<ListRoots>.self, from: rootsData)
                        let roots = [Root(uri: "file:///test", name: "Test")]
                        try await clientTransport.send(
                            JSONEncoder().encode(
                                ListRoots.response(id: rootsRequest.id, result: .init(roots: roots))
                            ))
                        #expect(try await rootsTask.value == roots)
                    } else {
                        await #expect(
                            throws: MCPError.methodNotFound("Roots is not supported by the client")
                        ) {
                            try await server.listRoots()
                        }
                    }
                }
            }
        } catch {
            await server.stop()
            await clientTransport.disconnect()
            throw error
        }

        await server.stop()
        await clientTransport.disconnect()
    }

    @Test("Connection")
    func testStdioTransportConnection() async throws {
        let (input, _) = try FileDescriptor.pipe()
        let (_, output) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()
        await transport.disconnect()
    }

    @Test("Send Message")
    func testStdioTransportSendMessage() async throws {
        let (reader, output) = try FileDescriptor.pipe()
        let (input, _) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()

        // Test sending a simple message
        let message = #"{"key":"value"}"#
        try await transport.send(message.data(using: .utf8)!)

        // Read and verify the output
        var buffer = [UInt8](repeating: 0, count: 1024)
        let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
            try reader.read(into: UnsafeMutableRawBufferPointer(pointer))
        }
        let data = Data(buffer[..<bytesRead])
        let expectedOutput = message.data(using: .utf8)! + "\n".data(using: .utf8)!
        #expect(data == expectedOutput)

        await transport.disconnect()
    }

    @Test("Receive Message")
    func testStdioTransportReceiveMessage() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (_, output) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()

        // Write test message to input pipe
        let message = ["key": "value"]
        let messageData = try JSONEncoder().encode(message) + "\n".data(using: .utf8)!
        try writer.writeAll(messageData)
        try writer.close()

        // Start receiving messages
        let stream: AsyncThrowingStream<Data, Swift.Error> = await transport.receive()
        var iterator = stream.makeAsyncIterator()

        // Get first message
        let received = try await iterator.next()
        #expect(received == #"{"key":"value"}"#.data(using: .utf8)!)

        await transport.disconnect()
    }

    @Test("Invalid JSON")
    func testStdioTransportInvalidJSON() async throws {
        let (input, writer) = try FileDescriptor.pipe()
        let (_, output) = try FileDescriptor.pipe()
        let transport = StdioTransport(input: input, output: output, logger: nil)
        try await transport.connect()

        // Write invalid JSON to input pipe
        let invalidJSON = #"{ invalid json }"#
        try writer.writeAll(invalidJSON.data(using: .utf8)!)
        try writer.close()

        let stream: AsyncThrowingStream<Data, Swift.Error> = await transport.receive()
        var iterator = stream.makeAsyncIterator()

        _ = try await iterator.next()

        await transport.disconnect()
    }

    @Test("Send Error")
    func testStdioTransportSendError() async throws {
        let (input, _) = try FileDescriptor.pipe()
        let transport = StdioTransport(
            input: input,
            output: FileDescriptor(rawValue: -1),  // Invalid fd
            logger: nil
        )

        do {
            try await transport.connect()
            #expect(Bool(false), "Expected connect to throw an error")
        } catch {
            #expect(error is MCPError)
        }

        await transport.disconnect()
    }

    @Test("Receive Error")
    func testStdioTransportReceiveError() async throws {
        let (_, output) = try FileDescriptor.pipe()
        let transport = StdioTransport(
            input: FileDescriptor(rawValue: -1),  // Invalid fd
            output: output,
            logger: nil
        )

        do {
            try await transport.connect()
            #expect(Bool(false), "Expected connect to throw an error")
        } catch {
            #expect(error is MCPError)
        }

        await transport.disconnect()
    }
}
