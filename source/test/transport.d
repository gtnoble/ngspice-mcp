module test.transport;

import std.json;
import mcp.protocol;
import mcp.transport.stdio : Transport;

alias MessageHandler = void delegate(JSONValue);

/**
 * Transport implementation for testing.
 *
 * This transport provides synchronous request-response handling
 * for testing MCP servers without the need for a full transport layer.
 */
class TestTransport : Transport {
    private MessageHandler messageHandler;
    private JSONValue lastMessage;

    /**
     * Create a new test transport.
     */
    this() {
        // Default message handler does nothing
        messageHandler = (JSONValue message) {};
    }

    /**
     * Send a message through this transport.
     * In test mode, this just stores the message.
     */
    override void sendMessage(JSONValue message) {
        lastMessage = message;
    }

    /**
     * Set the message handler for this transport.
     */
    override void setMessageHandler(MessageHandler handler) {
        messageHandler = handler;
    }

    /**
     * Start the transport.
     * Not used in test mode since we handle messages synchronously.
     */
    override void run() {
        // No-op for test transport
    }

    /**
     * Close the transport.
     * Not used in test mode.
     */
    override void close() {
        // No-op for test transport
    }

    /**
     * Process a message directly.
     * Used internally by the test transport.
     */
    override void handleMessage(JSONValue message) {
        messageHandler(message);
    }

    /**
     * Send a request and get the response.
     * This provides synchronous request-response for testing.
     */
    JSONValue sendRequest(Request request) {
        messageHandler(request.toJSON());
        return lastMessage;
    }
}
