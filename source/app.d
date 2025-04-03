import std.stdio;
import std.getopt;
import std.file;
import std.path;
import std.algorithm;
import std.array;

import database.schema;
import database.queries;
import parser.netlist;
import mcp.protocol;
import mcp.schema;
import mcp.server;
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
    
    @Option("log", "Path to log file for skipped parameters")
    string logPath;
}

void main(string[] args) {
    Config config;
    
    // Parse command line arguments
    auto helpInfo = args.getopt(
        "working-dir|d", "Working directory path", &config.workingDir,
        "db", "Database file path (defaults to embedded database)", &config.dbPath,
        "max-results", "Maximum number of query results", &config.maxResults,
        "log", "Path to log file for skipped parameters", &config.logPath
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
    
    // Initialize database
    auto dbConfig = DatabaseConfig(config.dbPath, config.maxResults);
    auto dbPool = new DatabasePool(dbConfig);
    auto queries = new DatabaseQueries(dbPool.getConnection());

    // Process netlist files if provided
    auto netlistFiles = args[1..$]
        .filter!(f => f.endsWith(".sp") || f.endsWith(".cir"))
        .array;

    if (netlistFiles.length > 0) {
        auto parser = new NetlistParser(config.logPath);
        foreach (file; netlistFiles) {
            writefln("Processing %s...", file);
            parser.parseFile(file, queries);
        }
        writeln("Model extraction complete");
        return;
    }

    // Start MCP server if no files to process
    writefln("Starting MCP server with database: %s", config.dbPath);
    auto server = new NgspiceServer(config.workingDir);
    
    // Add model query tool to server
    server.addModelQueryTool(dbPool);
    
    server.run();
}

/// Add the model query tool to the server
void addModelQueryTool(NgspiceServer server, DatabasePool dbPool) {
    auto tool = new Tool("queryModels");
    
    // Define schema for parameter ranges
    auto rangeSchema = new ObjectSchema()
        .addOptionalProperty("min", new NumberSchema())
        .addOptionalProperty("max", new NumberSchema());
    
    // Define input schema
    tool.setInputSchema(new ObjectSchema()
        .addProperty("modelType", new StringSchema())
        .addOptionalProperty("name", new StringSchema())
        .addOptionalProperty("parameterRanges", new ObjectSchema()
            .setAdditionalProperties(rangeSchema)));
    
    // Define output schema
    tool.setOutputSchema(new ObjectSchema()
        .setAdditionalProperties(new ObjectSchema()
            .addProperty("parameters", new ObjectSchema()
                .setAdditionalProperties(new StringSchema()))));
    
    // Set tool handler
    tool.setHandler((Json params) {
        auto queries = new DatabaseQueries(dbPool.getConnection());
        
        // Build filter from params
        ModelFilter filter;
        filter.modelType = params["modelType"].str;
        filter.maxResults = dbPool.getMaxResults();
        
        if (auto name = "name" in params) {
            filter.namePattern = name.str;
        }
        
        if (auto ranges = "parameterRanges" in params) {
            import std.typecons : Nullable;
            
            foreach (string param, value; ranges.objectNoRef) {
                ParameterRange range;
                
                if (auto min = "min" in value) {
                    range.min = Nullable!double(min.get!double);
                }
                if (auto max = "max" in value) {
                    range.max = Nullable!double(max.get!double);
                }
                
                filter.ranges[param] = range;
            }
        }
        
        // Execute query
        auto results = queries.queryModels(filter);
        
        // Format results as JSON
        Json output = Json.emptyObject;
        foreach (name, model; results) {
            Json modelJson = Json.emptyObject;
            Json paramsJson = Json.emptyObject;
            
            foreach (paramName, paramValue; model.parameters) {
                paramsJson[paramName] = Json(paramValue);
            }
            
            
            output[name] = modelJson;
        }
        
        return output;
    });
    
    server.addTool(tool);
}
