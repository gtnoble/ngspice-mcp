module test.output;

import server.output;
import std.format;
import std.string : strip, split, indexOf, toStringz;
import test.bindings: setString;
import std.conv: to;

// Test output buffer initialization and callbacks
unittest {
    import std.stdio : writeln;

    bool stdoutNotified = false;
    bool stderrNotified = false;

    initOutputBuffers(
        () { stdoutNotified = true; },
        () { stderrNotified = true; }
    );

    // Verify initial state
    auto initialStdout = getStdout().textContent;
    auto initialStderr = getStderr().textContent;
    assert(initialStdout == "", 
        format("Expected empty stdout, got: '%s'", initialStdout));
    assert(initialStderr == "", 
        format("Expected empty stderr, got: '%s'", initialStderr));

    // Test stdout capture
    char* testMessage;
    setString("Test message\n", testMessage);
    outputCallback(testMessage, 0, null);
    
    auto stdoutContent = getStdout().textContent;
    assert(stdoutContent.strip == "Test message", 
        format("Stdout content mismatch. Expected 'Test message', got '%s'", stdoutContent.strip));
    assert(stdoutNotified, "stdout notification callback not called");

    // Verify buffer is cleared after read
    assert(getStdout().textContent == "", 
        format("Buffer should be cleared after read, but contained: '%s'", getStdout().textContent));

    // Test stderr capture
    char* errorMessage;
    setString("Error message\n", errorMessage);
    outputCallback(errorMessage, 1, null);
    auto stderrContent = getStderr().textContent;
    assert(stderrContent.strip == "Error message", 
        format("Stderr content mismatch. Expected 'Error message', got '%s'", stderrContent.strip));
    assert(stderrNotified, "stderr notification callback not called");
    assert(getStderr().textContent == "", 
        format("Stderr buffer should be cleared after read, but contained: '%s'", getStderr().textContent));
}

// Test buffer management
unittest {
    import std.stdio : writeln;
    initOutputBuffers(null, null);

    // Test multiple lines
    char* line1Message;
    setString("Line 1\n", line1Message);
    outputCallback(line1Message, 0, null);
    
    char* line2Message;
    setString("Line 2\n", line2Message);
    outputCallback(line2Message, 0, null);
    
    char* line3Message;
    setString("Line 3\n", line3Message);
    outputCallback(line3Message, 0, null);

    auto content = getStdout().textContent;
    auto lines = content.split("\n");
    assert(lines.length == 3, 
        format("Expected 3 lines, got %s. Content was:\n%s", 
        lines.length, content));

    assert(content.indexOf("Line 1") >= 0, 
        format("'Line 1' not found in:\n%s", content));

    assert(content.indexOf("Line 2") >= 0, 
        format("'Line 2' not found in:\n%s", content)); 

    assert(content.indexOf("Line 3") >= 0,
        format("'Line 3' not found in:\n%s", content));

    // Test mixed stdout/stderr
    char* error1Message;
    setString("Error 1\n", error1Message);
    outputCallback(error1Message, 1, null);
    
    char* output1Message;
    setString("Output 1\n", output1Message);
    outputCallback(output1Message, 0, null);
    
    char* error2Message;
    setString("Error 2\n", error2Message);
    outputCallback(error2Message, 1, null);

    auto stderr = getStderr();
    auto errContent = stderr.textContent;
    assert(errContent.indexOf("Error 1") >= 0,
        format("'Error 1' not found in stderr content:\n%s", errContent));
    assert(errContent.indexOf("Error 2") >= 0,
        format("'Error 2' not found in stderr content:\n%s", errContent));
    assert(errContent.indexOf("Output 1") < 0,
        format("Unexpected 'Output 1' found in stderr content:\n%s", errContent));
}

// Test resource contents and unseen behavior
unittest {
    initOutputBuffers(null, null);

    // Test stdout resource - first message
    char* message1;
    setString("Message 1\n", message1);
    outputCallback(message1, 0, null);
    auto stdout = getStdout();
    assert(stdout.mimeType == "text/plain",
        format("Expected mimeType 'text/plain', got '%s'", stdout.mimeType));
    assert(stdout.textContent.strip == "Message 1",
        format("Expected content 'Message 1', got '%s'", stdout.textContent.strip));

    // Second read should be empty as buffer was cleared
    stdout = getStdout();
    assert(stdout.textContent == "", 
        format("Stdout buffer should be empty after read, but contained: '%s'", stdout.textContent));

    // Add new message and verify it's returned
    char* message2;
    setString("Message 2\n", message2);
    outputCallback(message2, 0, null);
    stdout = getStdout();
    assert(stdout.textContent.strip == "Message 2", 
        format("Expected 'Message 2', got '%s'", stdout.textContent.strip));

    // Test stderr resource - similar behavior
    char* errorMsg1;
    setString("Error 1\n", errorMsg1);
    outputCallback(errorMsg1, 1, null);
    auto stderr = getStderr();
    assert(stderr.mimeType == "text/plain",
        format("Expected mimeType 'text/plain', got '%s'", stderr.mimeType));
    assert(stderr.textContent.strip == "Error 1", 
        format("Expected 'Error 1', got '%s'", stderr.textContent.strip));

    // Second read should be empty as buffer was cleared
    stderr = getStderr();
    assert(stderr.textContent == "", 
        format("Stderr buffer should be empty after read, but contained: '%s'", stderr.textContent));
}

// Test output clearing and index reset
unittest {
    initOutputBuffers(null, null);

    // Add some output
    char* messageText;
    setString("Message\n", messageText);
    outputCallback(messageText, 0, null);
    
    char* errorText;
    setString("Error\n", errorText);
    outputCallback(errorText, 1, null);

    // Read both buffers
    auto stdout1 = getStdout().textContent;
    auto stderr1 = getStderr().textContent;
    assert(stdout1.strip == "Message",
        format("Expected stdout 'Message', got '%s'", stdout1.strip));
    assert(stderr1.strip == "Error",
        format("Expected stderr 'Error', got '%s'", stderr1.strip));

    // Clear buffers
    clearOutput();

    // Add new messages
    char* newMessage;
    setString("New Message\n", newMessage);
    outputCallback(newMessage, 0, null);
    
    char* newError;
    setString("New Error\n", newError);
    outputCallback(newError, 1, null);

    // Verify we get the new content
    auto stdout2 = getStdout().textContent;
    auto stderr2 = getStderr().textContent;
    assert(stdout2.strip == "New Message",
        format("Expected stdout 'New Message', got '%s'", stdout2.strip));
    assert(stderr2.strip == "New Error",
        format("Expected stderr 'New Error', got '%s'", stderr2.strip));
}

// Test output truncation
unittest {
    initOutputBuffers(null, null);

    // Generate large output
    foreach (i; 0..10000) {
        char* testLine;
        setString("Test line\n", testLine);
        outputCallback(testLine, 0, null);
    }

    // Test truncation marker
    assert(getStdout().textContent.indexOf("[...Output truncated...]") >= 0,
        format("Missing truncation marker in content:\n%s", getStdout().textContent));
}

// Test malformed input handling
unittest {
    initOutputBuffers(null, null);

    // Test empty string
    char* emptyString;
    setString("", emptyString);
    outputCallback(emptyString, 0, null);
    assert(getStdout().textContent == "",
        format("Expected empty stdout, got: '%s'", getStdout().textContent));

    // Test null terminator
    char* nullTerminatedMessage;
    setString("Test\0message\n", nullTerminatedMessage);
    outputCallback(nullTerminatedMessage, 0, null);
    assert(getStdout().textContent.indexOf("\0") < 0,
        format("Null terminator not handled in content:\n%s", getStdout().textContent));

}

// Test multiline parsing
unittest {
    initOutputBuffers(null, null);

    // Test various line endings
    char* multilineMessage;
    setString("Line1\nLine2\rLine3\r\nLine4", multilineMessage);
    outputCallback(multilineMessage, 0, null);

    auto content = getStdout().textContent;
    assert(content.indexOf("Line1") >= 0,
        format("'Line1' not found in content:\n%s", content));
    assert(content.indexOf("Line2") >= 0,
        format("'Line2' not found in content:\n%s", content));
    assert(content.indexOf("Line3") >= 0,
        format("'Line3' not found in content:\n%s", content));
    assert(content.indexOf("Line4") >= 0,
        format("'Line4' not found in content:\n%s", content));

    // Test line continuation
    char* part1Message;
    setString("Part1", part1Message);
    outputCallback(part1Message, 0, null);
    
}

// Test multiple sequential reads with unseen behavior
unittest {
    initOutputBuffers(null, null);

    // Add multiple messages
    char* msg1;
    setString("First\n", msg1);
    outputCallback(msg1, 0, null);
    
    char* msg2;
    setString("Second\n", msg2);
    outputCallback(msg2, 0, null);

    // First read should get both messages
    auto read1 = getStdout().textContent;
    assert(read1.indexOf("First") >= 0,
        format("'First' not found in first read:\n%s", read1));
    assert(read1.indexOf("Second") >= 0,
        format("'Second' not found in first read:\n%s", read1));

    // Second read should be empty
    auto read2 = getStdout().textContent;
    assert(read2 == "",
        format("Expected empty second read, got: '%s'", read2));

    // Add another message
    char* msg3;
    setString("Third\n", msg3);
    outputCallback(msg3, 0, null);

    // Third read should only get new message
    auto read3 = getStdout().textContent;
    assert(read3.indexOf("First") < 0,
        format("Unexpected 'First' found in third read:\n%s", read3));
    assert(read3.indexOf("Second") < 0,
        format("Unexpected 'Second' found in third read:\n%s", read3));
    assert(read3.indexOf("Third") >= 0,
        format("'Third' not found in third read:\n%s", read3));

    // Fourth read should be empty
    auto read4 = getStdout().textContent;
    assert(read4 == "",
        format("Expected empty fourth read, got: '%s'", read4));
}

// Test concurrent stdout/stderr handling with unseen behavior
unittest {
    bool stdoutNotified = false;
    bool stderrNotified = false;
    
    initOutputBuffers(
        () { stdoutNotified = true; },
        () { stderrNotified = true; }
    );

    // Interleave stdout and stderr
    char* out1Message;
    setString("stdout:Out1", out1Message);
    outputCallback(out1Message, 0, null);
    
    char* err1Message;
    setString("stderr:Err1", err1Message);
    outputCallback(err1Message, 1, null);
    
    char* out2Message;
    setString("stdout:Out2", out2Message);
    outputCallback(out2Message, 0, null);
    
    char* err2Message;
    setString("stderr:Err2", err2Message);
    outputCallback(err2Message, 1, null);
    
    char* newlineOut;
    setString("stdout:\n", newlineOut);
    outputCallback(newlineOut, 0, null);
    
    char* newlineErr;
    setString("stderr:\n", newlineErr);
    outputCallback(newlineErr, 1, null);

    auto stdout = getStdout();
    auto stderr = getStderr();
    auto stdoutContent = stdout.textContent;
    auto stderrContent = stderr.textContent;

    // Verify separation
    assert(stdoutContent.indexOf("Out1") >= 0,
        format("'Out1\nOut2' not found in stdout:\n%s", stdoutContent));
    assert(stdoutContent.indexOf("Err") < 0,
        format("Unexpected 'Err' found in stdout:\n%s", stdoutContent));
    
    assert(stderrContent.indexOf("Err1") >= 0,
        format("'Err1Err2' not found in stderr:\n%s", stderrContent));
    assert(stderrContent.indexOf("Out") < 0,
        format("Unexpected 'Out' found in stderr:\n%s", stderrContent));

    // Verify notifications
    assert(stdoutNotified, "stdout notification callback not called");
    assert(stderrNotified, "stderr notification callback not called");
}
