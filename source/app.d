import std.stdio;
import std.getopt;
import std.file;
import std.path;
import std.algorithm;
import std.array;

import d2sqlite3;
import mcp.protocol;
import server.ngspice_server;

/// Get the path to the embedded database
string getEmbeddedDatabasePath() {
    import std.file : thisExePath;
    import std.path : dirName, buildPath;
    
    // Get the directory containing the executable
    string exeDir = dirName(thisExePath());
    
    // Database is in the data subdirectory
    return buildPath(exeDir, "data", "models.db");
}

/// Application configuration
struct Config {
    @Option("working-dir", "d")
    string workingDir = ".";
    
    @Option("db", "Database file path (defaults to embedded database)")
    string dbPath = "";
    
    @Option("max-results", "Maximum number of query results")
    size_t maxResults = 20;
}

void main(string[] args) {
    Config config;
    
    // Parse command line arguments
    auto helpInfo = args.getopt(
        "working-dir|d", "Working directory path", &config.workingDir,
        "db", "Database file path (defaults to embedded database)", &config.dbPath,
        "max-results", "Maximum number of query results", &config.maxResults
    );

    if (helpInfo.helpWanted) {
        defaultGetoptPrinter(
            "Model extractor and MCP server for ngspice\n" ~
            "Usage: ngspice-mcp [options] [netlist files...]\n",
            helpInfo.options
        );
        return;
    }

    // If no custom database path provided, use the embedded one
    if (config.dbPath.length == 0) {
        config.dbPath = getEmbeddedDatabasePath();
    }
    
    writefln("Using database: %s", config.dbPath);
    
    // Open database connection
    auto db = Database(config.dbPath);
    
    // Start server
    writefln("Starting MCP server...");
    auto server = new NgspiceServer(100, config.workingDir, config.maxResults, db);
    
    server.start();
}
