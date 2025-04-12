import std.stdio;
import std.getopt;
import std.file;
import std.path;
import std.algorithm;
import std.array;

import mcp.protocol;
import server.ngspice_server;

/// Application configuration
struct Config {
    @Option("working-dir", "d")
    string workingDir = ".";
}

void main(string[] args) {
    Config config;
    
    // Parse command line arguments
    auto helpInfo = args.getopt(
        "working-dir|d", "Working directory path", &config.workingDir
    );

    if (helpInfo.helpWanted) {
        defaultGetoptPrinter(
            "MCP server for ngspice circuit simulation\n" ~
            "Usage: ngspice-mcp [options]\n",
            helpInfo.options
        );
        return;
    }
    
    // Start server
    auto server = new NgspiceServer(100, config.workingDir);
    
    server.start();
}
