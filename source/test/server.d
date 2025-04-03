module test.server;

import std.file : write, exists, remove;
import std.exception : assertThrown;
import std.string : format;
import std.json : JSONValue;
import std.conv : to;

import mcp.protocol : MCPError;
import mcp.transport.stdio : Transport;

import server.ngspice_server;

// Helper to create JSON arguments
private JSONValue serializeToJson(string[string] args) {
    JSONValue[string] jsonArgs;
    foreach (key, value; args) {
        jsonArgs[key] = JSONValue(value);
    }
    return JSONValue(jsonArgs);
}

// Helper function to create temporary netlist files
private string createTempNetlist(string content, string suffix = ".sp") {
    import std.uuid : randomUUID;
    string filename = format("test_netlist_%s%s", randomUUID(), suffix);
    write(filename, content);
    return filename;
}

@("loadNetlistFromFile with valid netlist")
unittest {
    // Create a test netlist file
    string validNetlist = "Test RC Circuit\nR1 in out 1k\nC1 out 0 1u\n.end";
    string filename = createTempNetlist(validNetlist);
    scope(exit) if (exists(filename)) remove(filename);

    // Create server instance
    auto server = new NgspiceServer();
    
    try {
        // Test loading from file
        auto result = server.testLoadNetlistFromFile(["filepath": filename].serializeToJson());
        assert(result["status"].str == "Circuit loaded successfully", 
            "Failed to load valid netlist file");
    } catch (Exception e) {
        assert(false, "Exception thrown for valid netlist: " ~ e.msg);
    }
}

@("loadNetlistFromFile with non-existent file")
unittest {
    auto server = new NgspiceServer();
    
    // Test with non-existent file
    assertThrown!MCPError(
        server.testLoadNetlistFromFile(["filepath": "nonexistent.sp"].serializeToJson()),
        "Failed to throw error for non-existent file"
    );
}

@("loadNetlistFromFile with empty file")
unittest {
    // Create empty test file
    string filename = createTempNetlist("");
    scope(exit) if (exists(filename)) remove(filename);

    auto server = new NgspiceServer();
    
    // Test with empty file
    assertThrown!MCPError(
        server.testLoadNetlistFromFile(["filepath": filename].serializeToJson()),
        "Failed to throw error for empty file"
    );
}

@("loadNetlistFromFile with various netlist variants")
unittest {
    // Test various valid netlist formats
    string[] validNetlists = [
        // Basic RC circuit
        "RC Circuit\nR1 in out 1k\nC1 out 0 1u\n.end",
        
        // Circuit with comments and whitespace
        "* Test Circuit\nR1 in out 1k  ; resistor\nC1 out 0 1u   ; capacitor\n\n.end",
        
        // Circuit with multiple components
        "Complex Circuit\nV1 in 0 DC 5\nR1 in out 1k\nC1 out 0 1u\nR2 out 0 10k\n.end"
    ];

    auto server = new NgspiceServer();

    foreach (netlist; validNetlists) {
        string filename = createTempNetlist(netlist);
        scope(exit) if (exists(filename)) remove(filename);

        try {
            auto result = server.testLoadNetlistFromFile(["filepath": filename].serializeToJson());
            assert(result["status"].str == "Circuit loaded successfully",
                "Failed to load valid netlist variant");
        } catch (Exception e) {
            assert(false, "Exception thrown for valid netlist variant: " ~ e.msg);
        }
    }
}
