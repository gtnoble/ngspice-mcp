/**
 * Output stream handling for ngspice MCP server.
 *
 * This module manages the stdout and stderr streams from ngspice,
 * buffering them and providing access through MCP resources.
 */
module server.output;

import std.array : appender, join;
import std.datetime : MonoTime;
import std.json : JSONValue;
import core.sync.mutex : Mutex;
import mcp.resources : ResourceContents;
import std.string : chomp;

/// Output stream buffer with thread-safe sliding window
final class OutputBuffer {
    private {
        Mutex mutex;                /// Lock for thread safety
        string[] window;            /// Sliding window of lines
        MonoTime lastUpdate;        /// Time of last update
        ResourceNotifier notifier;  /// Function to notify of changes
        const size_t maxLines = 1000; /// Max lines in window
        bool wasTruncated = false;  /// Track if lines were discarded
        enum TRUNC_MARKER = "[...Output truncated...]";
    }

    /// Constructor
    this(ResourceNotifier notifier) {
        mutex = new Mutex();
        window = [];
        lastUpdate = MonoTime.currTime;
        this.notifier = notifier;
    }

    /// Add a line of output
    void append(string line) {
        synchronized(mutex) {
            if (window.length >= maxLines) {
                window = window[1..$]; // Remove oldest line
                wasTruncated = true;
            }
            window ~= line.chomp;
            lastUpdate = MonoTime.currTime;
        }
        if (notifier) notifier();
    }

    /// Get all content, clear window, and include truncation marker if needed
    private string getAndClearContent() {
        synchronized(mutex) {
            string content;
            if (wasTruncated) {
                content = TRUNC_MARKER ~ "\n";
                wasTruncated = false;
            }
            content ~= window.join("\n");
            window = []; // Clear window
            return content;
        }
    }

    /// Get lines as resource contents (clears window after reading)
    ResourceContents getResourceContents() {
        synchronized(mutex) {
            return ResourceContents.makeText(
                "text/plain",
                getAndClearContent()
            );
        }
    }

    /// Get all lines as a string (for testing, doesn't clear window)
    string getContent() {
        synchronized(mutex) {
            string content;
            if (wasTruncated) {
                content = TRUNC_MARKER ~ "\n";
            }
            content ~= window.join("\n");
            return content;
        }
    }

    /// Clear the buffer
    void clear() {
        synchronized(mutex) {
            window = [];
            wasTruncated = false;
            lastUpdate = MonoTime.currTime;
        }
        if (notifier) notifier();
    }
}

/// Function to notify of resource changes
alias ResourceNotifier = void delegate();

/// Global output buffers
private {
    OutputBuffer stdout_buffer;
    OutputBuffer stderr_buffer;
}

/**
 * Initialize output buffers
 *
 * Must be called before using any output functions.
 *
 * Params:
 *   stdout_notifier = Function to call when stdout changes
 *   stderr_notifier = Function to call when stderr changes
 */
void initOutputBuffers(ResourceNotifier stdout_notifier, ResourceNotifier stderr_notifier) {
    stdout_buffer = new OutputBuffer(stdout_notifier);
    stderr_buffer = new OutputBuffer(stderr_notifier);
}

/**
 * Callback for receiving output from ngspice
 *
 * This function is passed to ngSpice_Init to handle output streams.
 * Output is classified as stderr if it starts with "stderr" or contains "Error".
 *
 * Params:
 *   str = The output string
 *   id = Identifier from ngspice (unused)
 *   user_data = User data pointer (unused)
 *
 * Returns: Always returns 0
 */
extern(C) int outputCallback(char* str, int id, void* user_data) {
    import std.string : fromStringz, startsWith, indexOf;
    string output = str.fromStringz.idup;

    // Detect if this is stderr output
    bool is_stderr = output.startsWith("stderr") || output.indexOf("Error") >= 0;

    // Add to appropriate buffer
    if (is_stderr) {
        stderr_buffer.append(output);
    } else {
        stdout_buffer.append(output);
    }

    return 0;
}

/// Get stdout contents
ResourceContents getStdout() {
    return stdout_buffer.getResourceContents();
}

/// Get stderr contents
ResourceContents getStderr() {
    return stderr_buffer.getResourceContents();
}

/// Clear stdout buffer
void clearStdout() {
    stdout_buffer.clear();
}

/// Clear stderr buffer
void clearStderr() {
    stderr_buffer.clear();
}

/// Clear both output buffers
void clearOutput() {
    clearStdout();
    clearStderr();
}
