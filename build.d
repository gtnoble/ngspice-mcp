module build;

import std.stdio;
import std.file;
import std.path;
import std.process;
import std.array;
import std.algorithm;

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
    
    // Remove existing database
    if (exists(dbPath)) {
        remove(dbPath);
        writeln("Removed existing database");
    }
    
    // Find all model files
    string[] modelFiles;
    if (exists(resourceDir)) {
        try {
            modelFiles = dirEntries(resourceDir, SpanMode.depth)
                .filter!(e => e.name.endsWith(".sp") || e.name.endsWith(".cir"))
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
    
    // Build extraction command
    auto cmd = ["dub", "run", "--config=build-tool", "--", 
                "--db=" ~ dbPath];
    
    // Add model files to command if any exist
    cmd ~= modelFiles;
    
    // Execute model extraction
    writeln("Executing: ", cmd.join(" "));
    auto result = execute(cmd);
    
    writeln("Command output:");
    writeln(result.output);
    
    if (result.status != 0) {
        writeln("Error building database: ", result.output);
        return;
    }
    
    writeln("Database built successfully at: ", dbPath);
}
