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
    
    @Option("max-points", "p")
    int maxPoints = 1000;
}

void main(string[] args) {
    Config config;
    
    // Parse command line arguments
    auto helpInfo = args.getopt(
        "working-dir|d", "Working directory path", &config.workingDir,
        "max-points|p", "Maximum number of points for vector data", &config.maxPoints
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
    setupServer(config.maxPoints, config.workingDir);
    
    ngspiceServer.start();
}
