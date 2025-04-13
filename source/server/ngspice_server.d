/**
 * MCP server implementation for ngspice.
 *
 * This module provides ngspice functionality through the Model Context Protocol.
 * Important: ngspice is not thread-safe or reentrant. This module uses global state
 * and automatically initializes ngspice at program startup.
 */
module server.ngspice_server;

import std.json : JSONValue;
import std.string : toStringz, fromStringz;
import std.algorithm : map;
import std.array : array, split;
import std.exception : enforce;
import std.math : sqrt, atan2, PI, floor, log10, pow, abs, copysign, round, isFinite;
import std.format : format;
import std.algorithm : filter, min, max;
import std.ascii : isDigit;
import std.complex : Complex, arg, abs;
import std.range : assumeSorted;
import std.traits : isNumeric;
import std.string : strip, toLower;


import std.functional : toDelegate;
import std.file : exists, readText;


public MCPServer ngspiceServer;  // Exposed for testing
private VectorInfo[string][string] vectorInfoMap;
// Global state
private:
    int maxPoints = 1000;
    bool initialized;
    string workingDir;


/**
 * Type for interpolation functions that map a scale value to an interpolated value
 */
alias InterpolationFunction(S, T) = T delegate(S);

/**
 * Create an interpolation function for a set of values.
 * 
 * Params:
 *   scaleValues = Array of scale values (e.g. time points)
 *   values = Array of values to interpolate between
 * Returns: A delegate that performs linear interpolation at any scale value
 */
InterpolationFunction!(double, T) findInterpolator(T)(const double[] scaleValues, const T[] values)
        if (is(T == double) || is(T == Complex!double))
{
    enforce(scaleValues.length >= 2, "Need at least 2 points for interpolation");
    enforce(scaleValues.length == values.length, "Scale and value arrays must match");

    return (double target) {
        // Validate target is within domain
        if (target < scaleValues[0] || target > scaleValues[$ - 1])
        {
            throw new MCPError(
                ErrorCode.invalidParams,
                format!"Target %g is outside interpolation domain [%g, %g]"(
                    target, scaleValues[0], scaleValues[$ - 1]
            )
            );
        }

        // Find surrounding indices using binary search
        size_t idx2 = scaleValues.assumeSorted.lowerBound(target).length;
        // Handle edge case where target is equal to the first scale value
        if (idx2 == 0)
        {
            return values[0];
        }
        size_t idx1 = idx2 - 1;

        // Calculate interpolation parameter
        auto t = (target - scaleValues[idx1]) / (scaleValues[idx2] - scaleValues[idx1]);

        // Linear interpolation
        return values[idx1] * (1.0 - t) + values[idx2] * t;
    };
}

/**
 * Create an interpolation function for a set of values.
 * 
 * Params:
 *   scaleValues = Array of scale values (e.g. time points)
 *   values = Array of values to interpolate between
 * Returns: A delegate that performs linear interpolation at any scale value
 */
InterpolationFunction!(Complex!double, Complex!double) findInterpolator(T)(
    const Complex!double[] scaleValues, const T[] values)
        if (is(T == double) || is(T == Complex!double))
{
    enforce(scaleValues.length >= 2, "Need at least 2 points for interpolation");
    enforce(scaleValues.length == values.length, "Scale and value arrays must match");

    return (Complex!double target) {
        // Validate target magnitude is within domain
        double targetMag = abs(target);
        double minMag = abs(scaleValues[0]);
        double maxMag = abs(scaleValues[$ - 1]);

        if (targetMag < minMag || targetMag > maxMag)
        {
            throw new MCPError(
                ErrorCode.invalidParams,
                format!"Target magnitude %g is outside interpolation domain [%g, %g]"(
                    targetMag, minMag, maxMag
            )
            );
        }

        // Find surrounding indices using magnitude-based binary search
        size_t idx2 = scaleValues.map!(x => abs(x))
            .array.assumeSorted.lowerBound(abs(target)).length;
        // Handle edge case where target is equal to the first scale value
        if (idx2 == 0)
        {
            return Complex!(double)(values[0]);
        }
        size_t idx1 = idx2 - 1;

        // Calculate interpolation parameter using complex arithmetic
        auto t = (target - scaleValues[idx1]) / (scaleValues[idx2] - scaleValues[idx1]);

        // Linear interpolation with complex parameter
        return values[idx1] * (Complex!double(1.0, 0) - t) + values[idx2] * t;
    };
}

import mcp.transport.stdio : Transport;
import mcp.server : MCPServer;
import mcp.schema : SchemaBuilder;
import mcp.protocol : MCPError, ErrorCode;
import mcp.resources : ResourceContents;
import mcp.prompts : PromptResponse, PromptMessage, PromptArgument;

import bindings.ngspice : 
    simulation_types,
    vecvaluesall_ptr,
    vecinfoall_ptr,
    ngSpice_Init,
    ngSpice_Command,
    ngSpice_Circ,
    ngSpice_CurPlot,
    dvec;
import server.output : 
    outputCallback,
    getStdout,
    getStderr,
    initOutputBuffers;
import server.prompts : ngspiceUsagePrompt;

/**
 * Information about a vector including its scale, type and data
 */
private struct VectorInfo
{
    string name; // Vector name
    string scaleName; // Name of the scale vector
    simulation_types type; // Vector type (voltage, current, etc)
    double[] realData; // Real data (if real vector)
    Complex!double[] complexData; // Complex data (if complex vector)
    bool isReal; // True if vector contains real data
}

/**
 * Set up the MCP server with tools, resources and prompts
 *
 * Params:
 *   transport = MCP transport layer
 *   points = Maximum number of points for vector data
 *   dir = Working directory for netlist files and operations
 */
public void setupServer(int points, string dir)
{
        enforce(!ngspiceServer, "Server is already set up");
        maxPoints = points;
        workingDir = dir;

        // Create server
        ngspiceServer = new MCPServer("ngspice", "1.0.0");

        // Set up server components
        setupPrompts();
        setupResources();
        setupTools();

        // Initialize ngspice with callbacks
        enforce(
            ngSpice_Init(
                &outputCallback,
                null, // Status handler (unused) 
                &ngspiceExit,
                &dataCallback,
                &initDataCallback,
                null, // BGThread handler (unused)
                null  // No user_data needed - using global state
                
        ) == 0,
        "Failed to initialize ngspice"
        );

    initialized = true;

        // Set working directory in ngspice
        enforce(
            ngSpice_Command(("cd " ~ dir).toStringz()) == 0,
            "Failed to set ngspice working directory"
        );
}

private void setupPrompts()
{
        enforce(ngspiceServer, "Server not initialized");

        // Add usage prompt
        ngspiceServer.addPrompt(
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
}

private void setupResources()
{
        enforce(ngspiceServer, "Server not initialized");

        // Add usage resource
        ngspiceServer.addResource(
            "usage://",
            "Usage Guide",
            "Comprehensive guide for using the ngspice MCP server",
            () => ResourceContents("text/markdown", ngspiceUsagePrompt())
        );

        // Add output resources and initialize buffers
        auto stdoutResource = ngspiceServer.addResource(
            "stdout://",
            "Standard Output",
            "Captured standard output from ngspice",
            toDelegate(&getStdout)
        );

        auto stderrResource = ngspiceServer.addResource(
            "stderr://",
            "Standard Error",
            "Captured error output from ngspice",
            toDelegate(&getStderr)
        );

        initOutputBuffers(stdoutResource, stderrResource);
}

private void setupTools()
{
        enforce(ngspiceServer, "Server not initialized");

        // Circuit loading tool
        ngspiceServer.addTool(
            "loadCircuit",
            "Load a circuit netlist",
            SchemaBuilder.object()
                .addProperty("netlist", SchemaBuilder.string_()
                    .setDescription("SPICE format netlist string. Must include circuit elements and .end directive. Example: 'RC Circuit\nR1 in out 1k\nC1 out 0 1u\n.end'")),
                toDelegate(&loadCircuitTool)
        );

        // Netlist file loading tool
        ngspiceServer.addTool(
            "loadNetlistFromFile",
            "Load a circuit netlist from a file",
            SchemaBuilder.object()
                .addProperty("filepath", SchemaBuilder.string_()
                    .setDescription("Full path to the netlist file to load. File must exist and contain a valid SPICE format netlist that includes circuit elements and .end directive.")),
                toDelegate(&loadNetlistFromFileTool)
        );

        // Simulation tool
        ngspiceServer.addTool(
            "runSimulation",
            "Run a simulation command",
            SchemaBuilder.object()
                .addProperty("command", SchemaBuilder.string_()
                    .setDescription("Simulation command to execute. Common commands:\n- op (DC operating point)\n- dc source start stop step\n- ac dec points fstart fend\n- tran step tstop")),
                toDelegate(&runSimulationTool)
        );

        // Simple plot listing tool
        ngspiceServer.addTool(
            "getPlotNames",
            "Get names of available plots",
            SchemaBuilder.object(),
            toDelegate(&getPlotNamesTool)
        );

        // Vector listing tool with detailed info
        ngspiceServer.addTool(
            "getVectorsInfo",
            "Get detailed information about vectors in a plot",
            SchemaBuilder.object()
                .addProperty("plot", SchemaBuilder.string_()
                    .setDescription("Name of the plot to query (e.g. 'tran1', 'ac1', 'dc1', 'op1'). Use getPlotNames to list available plots.")),
                toDelegate(&getVectorsInfoTool)
        );

        // Vector data tool
        ngspiceServer.addTool(
            "getVectorData",
            "Get data for multiple vectors",
            SchemaBuilder.object()
                .addProperty("vectors", SchemaBuilder.array(SchemaBuilder.string_())
                    .setDescription(
                    "Array of vector names to retrieve (e.g. ['v(out)', 'i(v1)']). Vector names are case-sensitive."))
                .addProperty("plot", SchemaBuilder.string_()
                    .setDescription(
                    "Name of the plot to query. Use getPlotNames to list available plots."))
                .addProperty("points", SchemaBuilder.array(SchemaBuilder.number())
                    .setDescription(
                    "Array of scale values at which to evaluate the vectors through interpolation"))
                .addProperty("representation",
                    SchemaBuilder.string_()
                    .enum_(["magnitude-phase", "rectangular", "both"])
                    .optional()
                    .setDescription("Format for complex data:\n- magnitude-phase: Returns magnitude and phase in degrees\n- rectangular: Returns real and imaginary components\n- both: Returns both representations")),
                toDelegate(&getVectorDataTool)
        );

        // Local extrema tool
        ngspiceServer.addTool(
            "getLocalExtrema",
            "Get local minima and maxima of vectors",
            SchemaBuilder.object()
                .addProperty("vectors", SchemaBuilder.array(SchemaBuilder.string_())
                    .setDescription(
                    "Array of vector names to analyze (e.g. ['v(out)', 'i(v1)']). Vector names are case-sensitive."))
                .addProperty("plot", SchemaBuilder.string_()
                    .setDescription(
                    "Name of the plot to query. Use getPlotNames to list available plots."))
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
                    .setDescription("Options for extrema detection")),
                toDelegate(&getLocalExtremaTool)
        );
}

private JSONValue loadCircuitTool(JSONValue args)
{
        enforce(initialized, "Ngspice not initialized");

        auto netlist = args["netlist"].str;
        auto lines = netlist.split("\n");

        // Check for quit command
        foreach (line; lines) {
            if (line.strip.toLower == "quit") {
                throw new MCPError(
                    ErrorCode.invalidParams,
                    "Quit command is not supported in netlists"
                );
            }
        }

        char*[] clines;
        clines.length = lines.length;
        for (int i = 0; i < clines.length; i++)
        {
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

        // Get plots using getPlotNames
        auto plotsResult = getPlotNamesTool(JSONValue.emptyObject);

        return JSONValue([
            "status": JSONValue("Circuit loaded and simulation run successfully"),
            "plots": plotsResult["plots"]
        ]);
}

private JSONValue runSimulationTool(JSONValue args)
{
        enforce(initialized, "Ngspice not initialized");

        string command = args["command"].str;
        enforce(
            ngSpice_Command(command.toStringz()) == 0,
            "Simulation command failed"
        );

        // Get plots using getPlotNames
        auto plotsResult = getPlotNamesTool(JSONValue.emptyObject);

        return JSONValue([
            "status": JSONValue("Command executed successfully"),
            "plots": plotsResult["plots"]
        ]);
}

private JSONValue getPlotNamesTool(JSONValue args)
{
        enforce(initialized, "Ngspice not initialized");

        // Create a local copy of keys to avoid concurrent access issues
        string[] plotNames;
        plotNames = (vectorInfoMap).keys.dup;

        return JSONValue([
                "plots": JSONValue(plotNames)
            ]);
}

private JSONValue getVectorsInfoTool(JSONValue args)
{
        enforce(initialized, "Ngspice not initialized");

        // Get plot name
        enforce("plot" in args, "Plot name must be specified");
        string plotName = args["plot"].str;
        enforce(plotName in vectorInfoMap, "Specified plot does not exist: " ~ plotName);

        JSONValue[] vectorsInfo;

        // Get plot's vector info mapping
        VectorInfo[string] plotVectors;
        plotVectors = vectorInfoMap[plotName];

        foreach (vectorName, vecInfo; plotVectors)
        {
            // Calculate min/max values
            JSONValue range;
            if (vecInfo.isReal && vecInfo.realData.length > 0)
            {
                // Real data
                double minVal = vecInfo.realData[0];
                double maxVal = vecInfo.realData[0];
                foreach (val; vecInfo.realData)
                {
                    if (val < minVal)
                        minVal = val;
                    if (val > maxVal)
                        maxVal = val;
                }
                range = JSONValue([
                    "min": JSONValue(minVal),
                    "max": JSONValue(maxVal)
                ]);
            }
            else if (!vecInfo.isReal && vecInfo.complexData.length > 0)
            {
                // Complex data - use magnitude
                double minVal = double.infinity;
                double maxVal = -double.infinity;
                foreach (val; vecInfo.complexData)
                {
                    double mag = abs(val); // Using Complex type's abs function
                    if (mag < minVal)
                        minVal = mag;
                    if (mag > maxVal)
                        maxVal = mag;
                }
                range = JSONValue([
                    "min": JSONValue(minVal),
                    "max": JSONValue(maxVal)
                ]);
            }

            // Build vector info object
            JSONValue vectorInfo = JSONValue([
                "name": JSONValue(vecInfo.name),
                "type": JSONValue(simulationTypeToString(vecInfo.type)),
                "isReal": JSONValue(vecInfo.isReal),
                "range": range,
                "scale": JSONValue([
                        "name": JSONValue(vecInfo.scaleName)
                    ])
            ]);

            vectorsInfo ~= vectorInfo;
        }

        return JSONValue([
                "vectors": JSONValue(vectorsInfo)
            ]);
}

private JSONValue loadNetlistFromFileTool(JSONValue args)
{
        enforce(initialized, "Ngspice not initialized");

        import std.path : buildPath, isAbsolute;

        string filepath = args["filepath"].str;

        // If path is not absolute, make it relative to working directory
        if (!isAbsolute(filepath))
        {
            filepath = buildPath(workingDir, filepath);
        }

        if (!exists(filepath))
        {
            throw new MCPError(
                ErrorCode.invalidRequest,
                "Netlist file does not exist: " ~ filepath
            );
        }

        string netlist = readText(filepath);
        if (netlist.length == 0)
        {
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

private JSONValue getVectorDataTool(JSONValue args)
{
        enforce(initialized, "Ngspice not initialized");

        // Get plot name
        enforce("plot" in args, "Plot name must be specified");
        string plotName = args["plot"].str;
        enforce(plotName in vectorInfoMap, "Specified plot does not exist: " ~ plotName);

        // Get plot's vector info mapping
        VectorInfo[string] plotVectors = vectorInfoMap[plotName];
        enforce(plotVectors.length > 0, "No vector information available for plot: " ~ plotName);

        // Get interpolation points
        double[] points;
        foreach (point; args["points"].array)
        {
            points ~= point.get!double;
        }

        // Check points are within scale range
        enforce(points.length > 0, "No interpolation points provided");
        enforce(points.length <= maxPoints,
            format!"Number of interpolation points (%d) exceeds maximum limit (%d)"(
                points.length, maxPoints
        )
        );

        // Process each vector
        JSONValue[string] vectorData;
        foreach (vector; args["vectors"].array)
        {
            string vectorName = vector.str;

            // Look up vector info
            auto vecInfoPtr = vectorName in plotVectors;
            if (vecInfoPtr is null)
            {
                vectorData[vectorName] = JSONValue([
                        "error": "Vector not found"
                    ]);
                continue;
            }
            auto vecInfo = *vecInfoPtr;

            // Look up scale vector info
            auto scaleVecInfoPtr = vecInfo.scaleName in plotVectors;
            if (scaleVecInfoPtr is null)
            {
                vectorData[vectorName] = JSONValue(
                    [
                    "error": format!"Scale vector not available: %s"(vecInfo.scaleName)
                ]);
                continue;
            }
            auto scaleVecInfo = *scaleVecInfoPtr;
            enforce(
                (scaleVecInfo.isReal && scaleVecInfo.realData.length > 0) ||
                    (!scaleVecInfo.isReal && scaleVecInfo.complexData.length > 0),
                    "Scale vector data not valid or empty: " ~ vecInfo.scaleName
            );

            // Handle empty vector
            if ((vecInfo.isReal && vecInfo.realData.length == 0) ||
                (!vecInfo.isReal && vecInfo.complexData.length == 0))
            {
                vectorData[vectorName] = JSONValue([
                    "length": JSONValue(0),
                    "data": JSONValue.emptyArray
                ]);
                continue;
            }

            // Get representation format
            string representation = "magnitude-phase";
            if ("representation" in args)
            {
                representation = args["representation"].str;
            }

            // Create interpolator for the vector
            JSONValue[] data;
            JSONValue[] scaleData;

            try {
                if (vecInfo.isReal)
                {
                    if (scaleVecInfo.isReal)
                    {
                        auto interpolator = findInterpolator!(double)(
                            (scaleVecInfo.realData), 
                            (vecInfo.realData)
                        );
                        foreach (point; points)
                        {
                            data ~= JSONValue(interpolator(point));
                            scaleData ~= JSONValue(point);
                        }
                    }
                    else
                    {
                        auto interpolator = findInterpolator!(double)(
                            (scaleVecInfo.complexData), 
                            (vecInfo.realData)
                        );
                        foreach (point; points)
                        {
                            auto value = interpolator(Complex!(double)(point));
                            data ~= formatComplexValue(value, representation);
                            scaleData ~= JSONValue(point);
                        }
                    }
                }
                else
                {
                    if (scaleVecInfo.isReal)
                    {
                        auto interpolator = findInterpolator!(Complex!double)(
                            (scaleVecInfo.realData), 
                            (vecInfo.complexData)
                        );
                        foreach (point; points)
                        {
                            auto value = interpolator(point);
                            data ~= formatComplexValue(value, representation);
                            scaleData ~= JSONValue(point);
                        }
                    }
                    else
                    {
                        auto interpolator = findInterpolator!(Complex!double)(
                            (scaleVecInfo.complexData), 
                            (vecInfo.complexData)
                        );
                        foreach (point; points)
                        {
                            auto value = interpolator(Complex!(double)(point));
                            data ~= formatComplexValue(value, representation);
                            scaleData ~= JSONValue(point);
                        }
                    }
                }

                // Store successful result
                JSONValue result = JSONValue([
                    "data": JSONValue(data),
                    "points": JSONValue(scaleData)
                ]);
                vectorData[vectorName] = result;
            }
            catch (MCPError e) {
                vectorData[vectorName] = JSONValue([
                    "error": JSONValue(e.message)
                ]);
                continue;  // Process next vector
            }
        }

        return JSONValue([
                "vectors": vectorData
            ]);
}

private JSONValue getLocalExtremaTool(JSONValue args)
{
        enforce(initialized, "Ngspice not initialized");

        // Get plot name
        enforce("plot" in args, "Plot name must be specified");
        string plotName = args["plot"].str;
        enforce(plotName in vectorInfoMap, "Specified plot does not exist: " ~ plotName);

        // Get plot's vector info mapping
        VectorInfo[string] plotVectors = vectorInfoMap[plotName];
        enforce(plotVectors.length > 0, "No vector information available for plot: " ~ plotName);

        // Get options
        bool findMinima = true;
        bool findMaxima = true;
        double threshold = 0.0;

        if ("options" in args)
        {
            auto options = args["options"];
            if ("minima" in options)
                findMinima = options["minima"].boolean;
            if ("maxima" in options)
                findMaxima = options["maxima"].boolean;
            if ("threshold" in options)
                threshold = options["threshold"].get!double;
        }

        // Process each vector
        JSONValue[string] vectorData;
        foreach (vector; args["vectors"].array)
        {
            string vectorName = vector.str;

            // Look up vector info
            auto vecInfoPtr = vectorName in plotVectors;
            if (vecInfoPtr is null)
            {
                vectorData[vectorName] = JSONValue([
                        "error": "Vector not found"
                    ]);
                continue;
            }
            auto vecInfo = *vecInfoPtr;

            // Look up scale vector info
            auto scaleVecInfoPtr = vecInfo.scaleName in plotVectors;
            if (scaleVecInfoPtr is null)
            {
                vectorData[vectorName] = JSONValue(
                    [
                    "error": format!"Scale vector not available: %s"(vecInfo.scaleName)
                ]);
                continue;
            }
            auto scaleVecInfo = *scaleVecInfoPtr;
            
            // Verify we have either real or complex data
            if ((scaleVecInfo.isReal && scaleVecInfo.realData.length == 0) ||
                (!scaleVecInfo.isReal && scaleVecInfo.complexData.length == 0))
            {
                vectorData[vectorName] = JSONValue(
                    [
                    "error": format!"Scale vector data not valid: %s"(vecInfo.scaleName)
                ]);
                continue;
            }

            // Process vector data and find extrema
            double[] values;
            if (vecInfo.isReal && vecInfo.realData.length > 0)
            {
                values = vecInfo.realData;
            }
            else if (!vecInfo.isReal && vecInfo.complexData.length > 0)
            {
                values = new double[](vecInfo.complexData.length);
                foreach (i, v; vecInfo.complexData)
                {
                    values[i] = abs(v); // Using Complex type's abs function
                }
            }
            else
            {
                vectorData[vectorName] = JSONValue([
                    "length": JSONValue(0),
                    "maxima": JSONValue.emptyArray,
                    "minima": JSONValue.emptyArray
                ]);
                continue;
            }

            // Find extrema
            int[] extremaIndices = findLocalExtrema(values, threshold, findMinima, findMaxima);

            // Build result arrays
            JSONValue[] minima;
            JSONValue[] maxima;

            foreach (idx; extremaIndices)
            {
                // Create extremum point info
                JSONValue point;
                if (scaleVecInfo.isReal) {
                    point = JSONValue([
                        "index": JSONValue(idx),
                        "value": JSONValue(values[idx]),
                        "scale": JSONValue(scaleVecInfo.realData[idx])
                    ]);
                } else {
                    point = JSONValue([
                        "index": JSONValue(idx),
                        "value": JSONValue(values[idx]),
                        "scale": formatComplexValue(scaleVecInfo.complexData[idx], "both")
                    ]);
                }

                // Add to appropriate array
                if (findMinima && values[idx] < values[max(0, idx - 1)] && values[idx] < values[min($ - 1, idx + 1)])
                {
                    minima ~= point;
                }
                else if (findMaxima && values[idx] > values[max(0, idx - 1)] && values[idx] > values[min($ - 1, idx + 1)])
                {
                    maxima ~= point;
                }
            }

            vectorData[vectorName] = JSONValue([
                "length": JSONValue(values.length),
                "maxima": JSONValue(maxima),
                "minima": JSONValue(minima)
            ]);
        }

        return JSONValue([
                "vectors": vectorData
            ]);
}

/**
 * Format a complex value according to the specified representation.
 */
private JSONValue formatComplexValue(Complex!double value, string representation)
{
    double magnitude = abs(value);
    double phase = arg(value) * (180.0 / PI); // Convert radians to degrees

    if (representation == "magnitude-phase")
    {
        return JSONValue([
            "magnitude": JSONValue(magnitude),
            "phase": JSONValue(phase)
        ]);
    }
    else if (representation == "rectangular")
    {
        return JSONValue([
            "real": JSONValue(value.re),
            "imag": JSONValue(value.im)
        ]);
    }
    else
    { // "both"
        return JSONValue([
            "real": JSONValue(value.re),
            "imag": JSONValue(value.im),
            "magnitude": JSONValue(magnitude),
            "phase": JSONValue(phase)
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
private int[] findLocalExtrema(const double[] values, double threshold = 0.0, bool minima = true, bool maxima = true)
{
    if (values.length < 3)
        return [];

    int[] extremaIndices;

    // Check each point against its neighbors
    for (int i = 1; i < values.length - 1; i++)
    {
        double prev = values[i - 1];
        double curr = values[i];
        double next = values[i + 1];

        bool isExtremum = false;

        if (maxima && curr > prev && curr > next)
        {
            // Found potential maximum
            double heightDiff = min(curr - prev, curr - next);
            if (heightDiff >= threshold)
            {
                isExtremum = true;
            }
        }
        else if (minima && curr < prev && curr < next)
        {
            // Found potential minimum
            double heightDiff = min(prev - curr, next - curr);
            if (heightDiff >= threshold)
            {
                isExtremum = true;
            }
        }

        if (isExtremum)
        {
            extremaIndices ~= i;
        }
    }

    return extremaIndices;
}

/**
 * Convert simulation_types enum to string representation.
 *
 * Params:
 *   type = The simulation_types enum value
 * Returns: String representation of the simulation type
 */
private string simulationTypeToString(simulation_types type)
{
    switch (type)
    {
    case simulation_types.SV_NOTYPE:
        return "none";
    case simulation_types.SV_TIME:
        return "time";
    case simulation_types.SV_FREQUENCY:
        return "frequency";
    case simulation_types.SV_VOLTAGE:
        return "voltage";
    case simulation_types.SV_CURRENT:
        return "current";
    case simulation_types.SV_VOLTAGE_DENSITY:
        return "voltage_density";
    case simulation_types.SV_CURRENT_DENSITY:
        return "current_density";
    case simulation_types.SV_SQR_VOLTAGE_DENSITY:
        return "squared_voltage_density";
    case simulation_types.SV_SQR_CURRENT_DENSITY:
        return "squared_current_density";
    case simulation_types.SV_SQR_VOLTAGE:
        return "squared_voltage";
    case simulation_types.SV_SQR_CURRENT:
        return "squared_current";
    case simulation_types.SV_POLE:
        return "pole";
    case simulation_types.SV_ZERO:
        return "zero";
    case simulation_types.SV_SPARAM:
        return "s_parameter";
    case simulation_types.SV_TEMP:
        return "temperature";
    case simulation_types.SV_RES:
        return "resistance";
    case simulation_types.SV_IMPEDANCE:
        return "impedance";
    case simulation_types.SV_ADMITTANCE:
        return "admittance";
    case simulation_types.SV_POWER:
        return "power";
    case simulation_types.SV_PHASE:
        return "phase";
    case simulation_types.SV_DB:
        return "decibel";
    case simulation_types.SV_CAPACITANCE:
        return "capacitance";
    case simulation_types.SV_CHARGE:
        return "charge";
    default:
        return "unknown";
    }
}

/**
 * Callback for receiving initial vector information
 */
extern (C) static int initDataCallback(vecinfoall_ptr data, int id, void* user_data)
{
        string plotName = data.type.fromStringz.idup;

        // Create/clear map for this plot
        VectorInfo[string] plotVectors;

        // Process each vector
        for (int i = 0; i < data.veccount; i++)
        {
            auto vec = data.vecs[i];
            if (vec.pdvecscale)
            {
                string vecName = vec.vecname.fromStringz.idup;
                VectorInfo info;
                info.name = vecName;
                info.scaleName = vec.pdvecscale.v_name.fromStringz.idup;
                info.type = vec.pdvec.v_type;
                info.isReal = vec.is_real;
                plotVectors[vecName] = info;
            }
        }

        // Store in plot map
        vectorInfoMap[plotName] = plotVectors;
        return 0;
}

/**
 * Callback for receiving vector data during simulation
 */
extern (C) static int dataCallback(vecvaluesall_ptr data, int count, int id, void* user_data)
{
        // Get current plot name
        char* curPlot = ngSpice_CurPlot();
        if (curPlot is null)
            return 0;
        string plotName = curPlot.fromStringz.idup;

        auto plotVectors = plotName in vectorInfoMap;
        if (plotVectors is null)
            return 0;

        // Process vector values
        for (int i = 0; i < data.veccount; i++)
        {
            auto val = data.vecsa[i];
            string vecName = val.name.fromStringz.idup;

            // Look up vector info
            auto vecInfo = vecName in *plotVectors;
            if (vecInfo is null)
                continue;

            if (val.is_complex)
            {
                // Add complex value
                (*vecInfo).complexData ~= Complex!double(val.real_value, val.imag_value);
            }
            else
            {
                // Add real value
                (*vecInfo).realData ~= val.real_value;
            }
        }

        return 0;
}

/**
 * Exit handler callback for ngspice
 */
extern(C) int ngspiceExit(int exitStatus, bool immediate, bool exitOnQuit, int id, void* userData) {
    // We don't actually exit, just return success
    return 0;
}
