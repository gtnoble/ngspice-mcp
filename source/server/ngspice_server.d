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
import std.algorithm : filter, min, max;
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

import bindings.ngspice;
import server.output;
import server.prompts : ngspiceUsagePrompt;

/**
 * NgspiceServer extends MCPServer with ngspice-specific functionality.
 */
class NgspiceServer : MCPServer {
    private bool initialized = false;
    private int maxPoints;
    private string workingDir;

    import std.typecons : Nullable, nullable;

    /**
     * Constructor using default stdio transport
     *
     * Sets up ngspice-specific tools and resources.
     *
     * Params:
     *   maxPoints = Maximum number of points for vector data
     *   workingDir = Working directory for netlist files and ngspice operations
     */
    this(int maxPoints, string workingDir) {
        super("ngspice", "1.0.0");
        this.maxPoints = maxPoints;
        this.workingDir = workingDir;
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
     */
    this(Transport transport, int maxPoints, string workingDir) {
        super(transport, "ngspice", "1.0.0");
        this.maxPoints = maxPoints;
        this.workingDir = workingDir;
        setupServer();
    }

    private void setupServer() {
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

        // Local extrema tool
        addTool(
            "getLocalExtrema",
            "Get local minima and maxima of vectors",
            SchemaBuilder.object()
                .addProperty("vectors", SchemaBuilder.array(SchemaBuilder.string_())
                    .setDescription("Array of vector names to analyze (e.g. ['v(out)', 'i(v1)']). Vector names are case-sensitive."))
                .addProperty("plot", SchemaBuilder.string_()
                    .optional()
                    .setDescription("Name of the plot to query. If omitted, uses current plot."))
                .addProperty("options", SchemaBuilder.object()
                    .addProperty("minima", SchemaBuilder.boolean()
                        .optional()
                        .setDescription("Include local minima in results (default: true)"))
                    .addProperty("maxima", SchemaBuilder.boolean()
                        .optional()
                        .setDescription("Include local maxima in results (default: true)"))
                    .addProperty("threshold", SchemaBuilder.number()
                        .optional()
                        .setDescription("Minimum height difference for extrema detection (default: 0)"))
                    .optional()
                    .setDescription("Options for extrema detection"))
                .addProperty("interval", SchemaBuilder.object()
                    .addProperty("start", SchemaBuilder.number()
                        .optional()
                        .setDescription("Start value of the scale vector (e.g. time or frequency)"))
                    .addProperty("end", SchemaBuilder.number()
                        .optional()
                        .setDescription("End value of the scale vector (e.g. time or frequency)"))
                    .optional()
                    .setDescription("Optional interval to limit data range")),
            &getLocalExtremaTool
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

    private JSONValue loadCircuitTool(JSONValue args) {
        enforce(this.initialized, "Ngspice not initialized");

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

        // Get plots using existing tool
        auto plotsResult = getPlotNamesTool(JSONValue.emptyObject);
        
        return JSONValue([
            "status": JSONValue("Circuit loaded and simulation run successfully"),
            "plots": plotsResult["plots"]  // Add plots from getPlotNamesTool
        ]);
    }

    private JSONValue runSimulationTool(JSONValue args) {
        enforce(this.initialized, "Ngspice not initialized");

        string command = args["command"].str;
        enforce(
            ngSpice_Command(command.toStringz()) == 0,
            "Simulation command failed"
        );

        // Get plots using existing tool
        auto plotsResult = getPlotNamesTool(JSONValue.emptyObject);
        
        return JSONValue([
            "status": JSONValue("Command executed successfully"),
            "plots": plotsResult["plots"]  // Add plots from getPlotNamesTool
        ]);
    }

    private JSONValue getPlotNamesTool(JSONValue args) {
        enforce(this.initialized, "Ngspice not initialized");

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
        enforce(this.initialized, "Ngspice not initialized");

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
        enforce(this.initialized, "Ngspice not initialized");

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
        enforce(this.initialized, "Ngspice not initialized");

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
    
    private JSONValue getLocalExtremaTool(JSONValue args) {
        enforce(this.initialized, "Ngspice not initialized");

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

        // Get options
        bool findMinima = true;
        bool findMaxima = true;
        double threshold = 0.0;

        if ("options" in args) {
            auto options = args["options"];
            if ("minima" in options) findMinima = options["minima"].boolean;
            if ("maxima" in options) findMaxima = options["maxima"].boolean;
            if ("threshold" in options) threshold = options["threshold"].get!double;
        }

        // Process each vector
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

            // Get interval bounds if specified
            int startIdx = 0;
            int endIdx = vec.v_length - 1;
            JSONValue intervalInfo;

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

            // Get scale vector for result formatting
            vector_info_ptr scale = ngGet_Vec_Info((plotName ~ ".scale").toStringz);

            // Process vector and find extrema
            JSONValue result = processVectorExtrema(
                vec, scale, startIdx, endIdx,
                findMinima, findMaxima, threshold
            );

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
 * Find local extrema in an array of real values.
 *
 * Params:
 *   values = Array of values to analyze
 *   threshold = Minimum height difference for extrema detection
 *   minima = Whether to find local minima
 *   maxima = Whether to find local maxima
 * Returns: Array of indices where extrema occur
 */
private int[] findLocalExtrema(const double[] values, double threshold = 0.0, bool minima = true, bool maxima = true) {
    if (values.length < 3) return [];
    
    int[] extremaIndices;
    
    // Check each point against its neighbors
    for (int i = 1; i < values.length - 1; i++) {
        double prev = values[i-1];
        double curr = values[i];
        double next = values[i+1];
        
        bool isExtremum = false;
        
        if (maxima && curr > prev && curr > next) {
            // Found potential maximum
            double heightDiff = min(curr - prev, curr - next);
            if (heightDiff >= threshold) {
                isExtremum = true;
            }
        }
        else if (minima && curr < prev && curr < next) {
            // Found potential minimum
            double heightDiff = min(prev - curr, next - curr);
            if (heightDiff >= threshold) {
                isExtremum = true;
            }
        }
        
        if (isExtremum) {
            extremaIndices ~= i;
        }
    }
    
    return extremaIndices;
}

/**
 * Get local extrema for a vector.
 */
private JSONValue processVectorExtrema(vector_info_ptr vec, vector_info_ptr scale, int startIdx, int endIdx, 
                                     bool findMinima, bool findMaxima, double threshold) {
    if (vec.v_length == 0) {
        return JSONValue([
            "length": JSONValue(0),
            "maxima": JSONValue.emptyArray,
            "minima": JSONValue.emptyArray
        ]);
    }

    // Get values for analysis
    double[] values;
    values.length = endIdx - startIdx + 1;

    if (vec.v_realdata) {
        // Real data - use directly
        for (int i = startIdx; i <= endIdx; i++) {
            values[i - startIdx] = vec.v_realdata[i];
        }
    }
    else if (vec.v_compdata) {
        // Complex data - use magnitude
        for (int i = startIdx; i <= endIdx; i++) {
            double realPart = vec.v_compdata[i].cx_real;
            double imagPart = vec.v_compdata[i].cx_imag;
            values[i - startIdx] = sqrt(realPart * realPart + imagPart * imagPart);
        }
    }

    // Find extrema
    int[] extremaIndices = findLocalExtrema(values, threshold, findMinima, findMaxima);

    // Build result arrays
    JSONValue[] minima;
    JSONValue[] maxima;

    foreach (int idx; extremaIndices) {
        // Create extremum point info
        JSONValue point = JSONValue([
            "index": JSONValue(idx + startIdx),
            "value": JSONValue(formatScientific(values[idx]))
        ]);

        // Add scale value if available
        if (scale && scale.v_realdata) {
            point["scale"] = JSONValue(formatScientific(scale.v_realdata[idx + startIdx]));
        }

        // Add to appropriate array
        if (findMinima && values[idx] < values[max(0, idx-1)] && values[idx] < values[min($-1, idx+1)]) {
            minima ~= point;
        }
        else if (findMaxima && values[idx] > values[max(0, idx-1)] && values[idx] > values[min($-1, idx+1)]) {
            maxima ~= point;
        }
    }

    return JSONValue([
        "length": JSONValue(endIdx - startIdx + 1),
        "maxima": JSONValue(maxima),
        "minima": JSONValue(minima)
    ]);
}


/**
 * Exit handler callback for ngspice
 */
extern(C) int ngspiceExit(int exitStatus, bool immediate, bool exitOnQuit, int id, void* userData) {
    // We don't actually exit, just return success
    return 0;
}
