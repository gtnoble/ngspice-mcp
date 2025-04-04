module build;

import std.stdio;
import std.file;
import std.path;
import std.process;
import std.array;
import std.algorithm;

import database.schema;
import database.queries;
import parser.netlist;
import d2sqlite3;

void main() {
    writeln("Building model database...");
    
    // Define paths
    string resourceDir = buildPath("resources", "models");
    string outputDir = buildPath("bin", "data");
    string dbPath = buildPath(outputDir, "models.db");
    
    // Create directories if they don't exist
    if (!exists(resourceDir)) {
        mkdirRecurse(resourceDir);
        writeln("Created resource directory: ", resourceDir);
    }
    
    if (!exists(outputDir)) {
        mkdirRecurse(outputDir);
        writeln("Created output directory: ", outputDir);
    }
    
    // Initialize database
    if (exists(dbPath)) {
        remove(dbPath);
        writeln("Removed existing database");
    }
    
    auto db = initializeDatabase(DatabaseConfig(dbPath));
    writeln("Initialized database schema");

    // Find all model files
    string[] modelFiles;
    if (exists(resourceDir)) {
        try {
            modelFiles = dirEntries(resourceDir, SpanMode.depth)
                .filter!(e => e.name.endsWith(".sp") || e.name.endsWith(".cir") || e.name.endsWith(".lib"))
                .map!(e => e.name)
                .array;
            
            writefln("Found %d model files", modelFiles.length);
        } catch (Exception e) {
            writeln("Error scanning model directory: ", e.msg);
        }
    }
    
    if (modelFiles.length == 0) {
        writeln("No model files found. Creating empty database.");
    }
    
    // Parse model files directly
    if (modelFiles.length > 0) {
        auto queries = new DatabaseQueries(db);
        auto parser = new NetlistParser(null);  // No log file for build process
        
        foreach (file; modelFiles) {
            writefln("Processing %s...", file);
            parser.parseFile(file, queries);
        }
    }
    
    writefln("Database built successfully at: %s", dbPath);
}
