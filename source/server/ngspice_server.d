/**
 * MCP server implementation for ngspice.
 *
 * This module provides the main server implementation that exposes
 * ngspice functionality through the Model Context Protocol.
 */
module server.ngspice_server;

import std.json : JSONValue;
import std.string : toStringz;
import std.algorithm : map;
import std.array : array, split;
import std.exception : enforce;
import std.math : sqrt, atan2, PI, floor, log10, pow, abs, copysign, round, isFinite;
import std.format : format;
import std.algorithm : filter;
import std.string : startsWith;
import std.ascii : isDigit;

import std.functional : toDelegate;
import std.file : exists, readText;

import mcp.transport.stdio : Transport;
import mcp.server : MCPServer;
import mcp.schema : SchemaBuilder;
import mcp.protocol : MCPError, ErrorCode;
import mcp.resources : ResourceContents;
import mcp.prompts : PromptResponse, PromptMessage, PromptArgument;

import d2sqlite3;
import bindings.ngspice;
import database.queries;
import server.output;
import server.prompts : ngspiceUsagePrompt;

/**
 * NgspiceServer extends MCPServer with ngspice-specific functionality.
 */
class NgspiceServer : MCPServer {
    private bool initialized = false;
    private int maxPoints;
    private string workingDir;
    private Nullable!Database db;
    private size_t maxResults;

    import std.typecons : Nullable, nullable;

    /**
     * Constructor using default stdio transport
     *
     * Sets up ngspice-specific tools and resources.
     *
     * Params:
     *   maxPoints = Maximum number of points for vector data
     *   workingDir = Working directory for netlist files and ngspice operations
     *   db = Database connection for model queries
     *   maxResults = Maximum number of query results
     */
    /**
     * Constructor with optional database parameter.
     *
     * Sets up ngspice-specific tools and resources.
     *
     * Params:
     *   maxPoints = Maximum number of points for vector data
     *   workingDir = Working directory for netlist files and ngspice operations
     *   maxResults = Maximum number of query results
     *   db = Optional database connection for model queries (default: Database.init)
     */
    this(int maxPoints, string workingDir, size_t maxResults, Database db = Database.init) {
        super("ngspice", "1.0.0");
        this.maxPoints = maxPoints;
        this.workingDir = workingDir;
        this.maxResults = maxResults;
        if (db != Database.init) {
            this.db = nullable(db);
        }
        setupServer();
    }

    /**
     * Constructor with transport and configuration options
     *
     * Sets up ngspice-specific tools and resources.
     *
     * Params:
     *   transport = MCP transport layer
     *   maxPoints = Maximum number of points for vector data
     *   workingDir = Working directory for netlist files and ngspice operations
     *   maxResults = Maximum number of query results
     *   db = Optional database connection for model queries (default: Database.init)
     */
    this(Transport transport, int maxPoints, string workingDir, size_t maxResults, Database db = Database.init) {
        super(transport, "ngspice", "1.0.0");
        this.maxPoints = maxPoints;
        this.workingDir = workingDir;
        this.maxResults = maxResults;
        if (db != Database.init) {
            this.db = nullable(db);
        }
        setupServer();
    }

    private void setupServer() {
        // Add model query tool if database is provided
        if (!db.isNull) {
            setupModelQueryTool();
        }

        // Add usage prompt for LLMs
        addPrompt(
            "usage",
            "Instructions for using the ngspice MCP server",
            [], // No arguments needed
            (string name, string[string] args) {
                return PromptResponse(
                    "Comprehensive guide for using the ngspice MCP server",
                    [
                        PromptMessage.text("assistant", ngspiceUsagePrompt())
                    ]
                );
            }
        );

        // Add usage resource that returns the usage prompt
        addResource(
            "usage://",
            "Usage Guide",
            "Comprehensive guide for using the ngspice MCP server",
            () => ResourceContents("text/markdown", ngspiceUsagePrompt())
        );

        // Initialize output buffers with resource notifiers using toDelegate
        initOutputBuffers(
            addResource(
                "stdout://",
                "Standard Output",
                "Captured standard output from ngspice",
                toDelegate(&getStdout)
            ),
            addResource(
                "stderr://",
                "Standard Error",
                "Captured error output from ngspice",
                toDelegate(&getStderr)
            )
        );

        // Add tools
        setupTools();

        // Initialize ngspice
        initNgspice();
    }

    private void setupTools() {
        // Circuit loading tool
        addTool(
            "loadCircuit",
            "Load a circuit netlist",
            SchemaBuilder.object()
                .addProperty("netlist", SchemaBuilder.string_()
                    .setDescription("SPICE format netlist string. Must include circuit elements and .end directive. Example: 'RC Circuit\nR1 in out 1k\nC1 out 0 1u\n.end'")),
            &loadCircuitTool
        );

        // Netlist file loading tool
        addTool(
            "loadNetlistFromFile",
            "Load a circuit netlist from a file",
            SchemaBuilder.object()
                .addProperty("filepath", SchemaBuilder.string_()
                    .setDescription("Full path to the netlist file to load. File must exist and contain a valid SPICE format netlist that includes circuit elements and .end directive.")),
            &loadNetlistFromFileTool
        );

        // Simulation tool
        addTool(
            "runSimulation",
            "Run a simulation command",
            SchemaBuilder.object()
                .addProperty("command", SchemaBuilder.string_()
                    .setDescription("Simulation command to execute. Common commands:\n- op (DC operating point)\n- dc source start stop step\n- ac dec points fstart fend\n- tran step tstop")),
            &runSimulationTool
        );

        // Plot listing tool
        addTool(
            "getPlotNames",
            "Get names of available plots",
            SchemaBuilder.object(),
            &getPlotNamesTool
        );

        // Vector listing tool
        addTool(
            "getVectorNames",
            "Get names of vectors in a plot",
            SchemaBuilder.object()
                .addProperty("plot", SchemaBuilder.string_()
                    .optional()
                    .setDescription("Name of the plot to query (e.g. 'tran1', 'ac1', 'dc1', 'op1'). Use getPlotNames to list available plots. If omitted, uses current plot.")),
            &getVectorNamesTool
        );

        // Vector data tool
        addTool(
            "getVectorData",
            "Get data for multiple vectors",
            SchemaBuilder.object()
                .addProperty("vectors", SchemaBuilder.array(SchemaBuilder.string_())
                    .setDescription("Array of vector names to retrieve (e.g. ['v(out)', 'i(v1)']). Vector names are case-sensitive. Note: The number of returned points is limited by the --max-points command line option (default: 100)."))
                .addProperty("plot", SchemaBuilder.string_()
                    .optional()
                    .setDescription("Name of the plot to query. If omitted, uses current plot."))
                .addProperty("representation",
                    SchemaBuilder.string_()
                        .enum_(["magnitude-phase", "rectangular", "both"])
                        .optional()
                        .setDescription("Format for complex data:\n- magnitude-phase: Returns magnitude and phase in degrees\n- rectangular: Returns real and imaginary components\n- both: Returns both representations"))
                .addProperty("interval",
                    SchemaBuilder.object()
                        .addProperty("start", SchemaBuilder.number()
                            .optional()
                            .setDescription("Start value of the scale vector (e.g. time or frequency)"))
                        .addProperty("end", SchemaBuilder.number()
                            .optional()
                            .setDescription("End value of the scale vector (e.g. time or frequency)"))
                        .optional()
                        .setDescription("Optional interval to limit data range")),
            &getVectorDataTool
        );
    }

    private void initNgspice() {
        // Validate working directory exists
        import std.file : exists, isDir;
        enforce(
            exists(workingDir) && isDir(workingDir),
            "Working directory does not exist or is not a directory: " ~ workingDir
        );

        // Initialize ngspice
        enforce(
            ngSpice_Init(
                &outputCallback,      // Stdout/stderr handler
                null,                 // Status handler (unused)
                &ngspiceExit,        // Exit handler
                null,                 // Data handler (unused)
                null,                 // Init handler (unused)
                null,                 // BGThread handler (unused)
                null                 // User data (unused)
            ) == 0,
            "Failed to initialize ngspice"
        );
        initialized = true;

        // Set ngspice's working directory
        import std.path : absolutePath;
        string absPath = absolutePath(workingDir);
        enforce(
            ngSpice_Command(("cd " ~ absPath).toStringz()) == 0,
            "Failed to set ngspice working directory to: " ~ absPath
        );
    }

    // Tool implementations

    private void setupModelQueryTool() {
        auto schema = SchemaBuilder.object()
            .addProperty("modelType", SchemaBuilder.string_()
                .setDescription("Type of model to query (e.g. 'nmos', 'pmos', 'diode')"))
            .addProperty("name", SchemaBuilder.string_()
                .setDescription("Pattern to match model names"))
                .optional()
            .addProperty("parameterRanges", SchemaBuilder.object()
                .addProperty("min", SchemaBuilder.number())
                    .setDescription("Minimum value for the parameter")
                    .optional()
                .addProperty("max", SchemaBuilder.number())
                    .setDescription("Maximum value for the parameter")
                    .optional()
                .setDescription("Parameter range constraints"))
                .optional();

        addTool(
            "queryModels",
            "Query device models from the database",
            schema,
            &queryModelsTool
        );
    }

    private JSONValue queryModelsTool(JSONValue args) {
        enforce(!db.isNull, "Database not initialized");
        auto queries = new DatabaseQueries(db.get());
        
        // Build filter from params
        ModelFilter filter;
        filter.modelType = args["modelType"].str;
        filter.maxResults = maxResults;
        
        if (auto name = "name" in args) {
            filter.namePattern = name.str;
        }
        
        if (auto ranges = "parameterRanges" in args) {
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
        JSONValue output = JSONValue.emptyObject;
        foreach (name, model; results) {
            JSONValue modelJson = JSONValue.emptyObject;
            JSONValue paramsJson = JSONValue.emptyObject;
            
            foreach (paramName, paramValue; model.parameters) {
                paramsJson[paramName] = JSONValue(paramValue);
            }
            
            modelJson["parameters"] = paramsJson;
            output[name] = modelJson;
        }
        
        return output;
    }

    private JSONValue loadCircuitTool(JSONValue args) {
        enforce(initialized, "Ngspice not initialized");

        auto netlist = args["netlist"].str;
        auto lines = netlist.split("\n");
        char*[] clines;
        clines.length = lines.length;
        for (int i = 0; i < clines.length; i++) {
            char[] line = (lines[i] ~ '\0').dup;
            clines[i] = line.ptr;
        }
        clines ~= null;

        enforce(
            ngSpice_Circ(clines.ptr) == 0,
            "Failed to load circuit"
        );
        
        // Run simulation automatically after loading
        enforce(
            ngSpice_Command("run") == 0,
            "Failed to run simulation"
        );

        return JSONValue([
            "status": "Circuit loaded and simulation run successfully"
        ]);
    }

    private JSONValue runSimulationTool(JSONValue args) {
        enforce(initialized, "Ngspice not initialized");

        string command = args["command"].str;
        enforce(
            ngSpice_Command(command.toStringz()) == 0,
            "Simulation command failed"
        );

        return JSONValue([
            "status": "Command executed successfully"
        ]);
    }

    private JSONValue getPlotNamesTool(JSONValue args) {
        enforce(initialized, "Ngspice not initialized");

        char** plots = ngSpice_AllPlots();
        string[] plotNames;
        
        for (int i = 0; plots[i] != null; i++) {
            import std.string : fromStringz;
            plotNames ~= plots[i].fromStringz.idup;
        }

        return JSONValue([
            "plots": plotNames
        ]);
    }

    private JSONValue getVectorNamesTool(JSONValue args) {
        enforce(initialized, "Ngspice not initialized");

        // Get plot name - either specified or current
        string plotName;
        if ("plot" in args) {
            plotName = args["plot"].str;
            // Verify plot exists
            bool plotFound = false;
            char** plots = ngSpice_AllPlots();
            for (int i = 0; plots[i] != null; i++) {
                import std.string : fromStringz;
                if (plots[i].fromStringz == plotName) {
                    plotFound = true;
                    break;
                }
            }
            enforce(plotFound, "Specified plot does not exist: " ~ plotName);
        } else {
            char* curPlot = ngSpice_CurPlot();
            enforce(curPlot !is null, "No current plot available");
            import std.string : fromStringz;
            plotName = curPlot.fromStringz.idup;
        }

        char** vectors = ngSpice_AllVecs(plotName.toStringz());
        string[] vectorNames;
        
        for (int i = 0; vectors[i] != null; i++) {
            import std.string : fromStringz;
            vectorNames ~= vectors[i].fromStringz.idup;
        }

        return JSONValue([
            "vectors": vectorNames
        ]);
    }

    private JSONValue loadNetlistFromFileTool(JSONValue args) {
        enforce(initialized, "Ngspice not initialized");

        import std.path : buildPath, isAbsolute;
        string filepath = args["filepath"].str;
        
        // If path is not absolute, make it relative to working directory
        if (!isAbsolute(filepath)) {
            filepath = buildPath(workingDir, filepath);
        }

        if (!exists(filepath)) {
            throw new MCPError(
                ErrorCode.invalidRequest,
                "Netlist file does not exist: " ~ filepath
            );
        }

        string netlist = readText(filepath);
        if (netlist.length == 0) {
            throw new MCPError(
                ErrorCode.invalidParams, 
                "Netlist file is empty: " ~ filepath
            );
        }
        
        // Reuse existing loadCircuit tool
        return loadCircuitTool(JSONValue([
            "netlist": JSONValue(netlist)
        ]));
    }

    version(unittest) {
        // Expose loadNetlistFromFileTool for testing
        JSONValue testLoadNetlistFromFile(JSONValue args) {
            return loadNetlistFromFileTool(args);
        }
    }


    /**
     * Find the indices in a real array that correspond to an interval
     */
    private void findIntervalIndices(const double[] values, double start, double end, out int startIdx, out int endIdx) {
        import std.algorithm : min, max;
        
        // Handle missing bounds
        if (start == double.nan) start = values[0];
        if (end == double.nan) end = values[$-1];

        // Ensure valid order
        if (start > end) {
            auto tmp = start;
            start = end;
            end = tmp;
        }

        // Find indices using binary search
        startIdx = 0;
        endIdx = cast(int)values.length - 1;

        // Find start index
        int low = 0;
        int high = cast(int)values.length - 1;
        while (low <= high) {
            int mid = (low + high) / 2;
            if (values[mid] < start)
                low = mid + 1;
            else
                high = mid - 1;
        }
        startIdx = max(0, low);

        // Find end index
        low = startIdx;
        high = cast(int)values.length - 1;
        while (low <= high) {
            int mid = (low + high) / 2;
            if (values[mid] <= end)
                low = mid + 1;
            else
                high = mid - 1;
        }
        endIdx = min(cast(int)values.length - 1, high);
    }

    private JSONValue getVectorDataTool(JSONValue args) {
        enforce(initialized, "Ngspice not initialized");

        // Get plot name - either specified or current
        string plotName;
        if ("plot" in args) {
            plotName = args["plot"].str;
            // Verify plot exists
            bool plotFound = false;
            char** plots = ngSpice_AllPlots();
            for (int i = 0; plots[i] != null; i++) {
                import std.string : fromStringz;
                if (plots[i].fromStringz == plotName) {
                    plotFound = true;
                    break;
                }
            }
            enforce(plotFound, "Specified plot does not exist: " ~ plotName);
        } else {
            char* curPlot = ngSpice_CurPlot();
            enforce(curPlot !is null, "No current plot available");
            import std.string : fromStringz;
            plotName = curPlot.fromStringz.idup;
        }

        JSONValue[string] vectorData;
        foreach (vector; args["vectors"].array) {
            string vectorName = vector.str;
            
            // Format vector name with plot prefix if not already included
            if (!vectorName.startsWith(plotName ~ ".")) {
                vectorName = plotName ~ "." ~ vectorName;
            }
            
            vector_info_ptr vec = ngGet_Vec_Info(vectorName.toStringz());
            
            // Handle vector not found
            if (vec is null) {
                vectorData[vectorName] = JSONValue([
                    "error": "Vector not found"
                ]);
                continue;
            }

            // Handle empty vector
            if (vec.v_length == 0) {
                vectorData[vectorName] = JSONValue([
                    "length": JSONValue(0),
                    "data": JSONValue.emptyArray
                ]);
                continue;
            }

            // Get interval bounds if specified
            int startIdx = 0;
            int endIdx = vec.v_length - 1;
            JSONValue intervalInfo;

            // Calculate points count before processing interval
            int totalPoints = vec.v_length;

            if ("interval" in args) {
                auto interval = args["interval"];
                double start = ("start" in interval) ? interval["start"].get!double : double.nan;
                double end = ("end" in interval) ? interval["end"].get!double : double.nan;

                // Find scale vector using specified plot
                vector_info_ptr scale = ngGet_Vec_Info((plotName ~ ".scale").toStringz);
                if (scale && scale.v_realdata) {
                    findIntervalIndices(scale.v_realdata[0..scale.v_length], start, end, startIdx, endIdx);
                    intervalInfo = JSONValue([
                        "start": scale.v_realdata[startIdx],
                        "end": scale.v_realdata[endIdx]
                    ]);
                }
            }

            // Check number of points after interval selection
            int pointCount = endIdx - startIdx + 1;
            if (pointCount > maxPoints) {
                throw new MCPError(
                    ErrorCode.invalidRequest,
                    format!"Vector data exceeds maximum points limit (%d points requested, limit is %d)"(
                        pointCount, maxPoints
                    )
                );
            }

            // Extract data for the interval
            JSONValue[] data;
            string representation = "magnitude-phase";
            if ("representation" in args) {
                representation = args["representation"].str;
            }

            if (vec.v_realdata) {
                // Real data
                for (int i = startIdx; i <= endIdx; i++) {
                    data ~= JSONValue(formatScientific(vec.v_realdata[i]));
                }
            } else if (vec.v_compdata) {
                // Complex data
                for (int i = startIdx; i <= endIdx; i++) {
                    data ~= formatComplexValue(
                        vec.v_compdata[i].cx_real,
                        vec.v_compdata[i].cx_imag,
                        representation
                    );
                }
            }

            // Create result
            JSONValue result = JSONValue([
                "length": JSONValue(endIdx - startIdx + 1),
                "data": JSONValue(data)
            ]);

            // Add interval info if present
            if (intervalInfo != JSONValue.init) {
                result["interval"] = intervalInfo;
            }

            vectorData[vectorName] = result;
        }

        return JSONValue([
            "vectors": vectorData
        ]);
    }
}

/**
 * Format a number in scientific notation with specified decimal places.
 *
 * Params:
 *   value = The number to format
 *   decimalPlaces = Number of decimal places (default: 2)
 * Returns: String representation in scientific notation
 */
private string formatScientific(double value, int decimalPlaces = 2) {
    import std.math : isFinite;
    import std.format : format;
    
    if (!value.isFinite) return format!"%g"(value);
    if (value == 0.0) return format!"0.%de+00"(decimalPlaces);
    
    return format!"%.*e"(decimalPlaces, value);
}

/**
 * Round a number to a specified number of significant figures.
 */
double roundToSigFigs(double value, int sigFigs = 3) {
    import std.math : abs, copysign, floor, log10, pow, round;

    // Handle special cases
    if (value == 0.0 || !value.isFinite || sigFigs <= 0) return value;
    
    // Get absolute value and sign
    double absVal = abs(value);
    double sign = copysign(1.0, value);
    
    // Find magnitude (position of leftmost digit)
    double magnitude = floor(log10(absVal));
    
    // Calculate scaling factor
    double scaleFactor = pow(10.0, sigFigs - magnitude - 1);
    
    // Scale up, round to integer, scale back down
    double rounded = round(absVal * scaleFactor) / scaleFactor;
    
    // Restore sign and handle edge cases near power-of-10 boundaries
    double result = sign * rounded;
    
    // Verify significant figures
    string numStr = format!"%.15g"(abs(result));
    auto digits = numStr.filter!(c => c.isDigit).array.length;
    if (digits > sigFigs) {
        // Re-scale if we got too many significant figures
        scaleFactor = pow(10.0, sigFigs - floor(log10(abs(result))) - 1);
        rounded = round(abs(result) * scaleFactor) / scaleFactor;
        result = sign * rounded;
    }
    
    return result;
}

/**
 * Format a complex value according to the specified representation.
 */
private JSONValue formatComplexValue(double real_part, double imag_part, string representation) {
    double magnitude = sqrt(real_part * real_part + imag_part * imag_part);
    double phase = atan2(imag_part, real_part) * (180.0 / PI);  // Convert to degrees
    
    if (representation == "magnitude-phase") {
        return JSONValue([
            "magnitude": formatScientific(magnitude),
            "phase": formatScientific(phase) 
        ]);
    }
    else if (representation == "rectangular") {
        return JSONValue([
            "real": formatScientific(real_part),
            "imag": formatScientific(imag_part)
        ]);
    }
    else { // "both"
        return JSONValue([
            "real": formatScientific(real_part),
            "imag": formatScientific(imag_part),
            "magnitude": formatScientific(magnitude),
            "phase": formatScientific(phase)
        ]);
    }
}

/**
 * Exit handler callback for ngspice
 */
extern(C) int ngspiceExit(int exitStatus, bool immediate, bool exitOnQuit, int id, void* userData) {
    // We don't actually exit, just return success
    return 0;
}
