module test.server;

import std.file : write, exists, remove;
import std.exception : assertThrown;
import std.string : startsWith, indexOf;
import std.format : format;
import std.json : JSONValue;
import std.conv : to;
import std.math : abs, PI, sqrt, atan2, sin, cos;
import std.algorithm : endsWith, min, max, map;
import std.array : array;
import std.complex : Complex, abs, arg;

import mcp.protocol : MCPError;
import mcp.transport.stdio : Transport;

import server.ngspice_server;

// Helper function for relative comparison of floating-point values
private bool isRelativelyEqual(double actual, double expected, double tolerance = 0.05) {
    if (expected == 0) {
        return abs(actual) < tolerance;
    }
    return abs((actual - expected)/expected) < tolerance;
}

// Helper function for relative comparison of complex numbers
private bool isRelativelyEqual(Complex!double actual, Complex!double expected, double tolerance = 0.05) {
    // Compare magnitudes
    double actualMag = abs(actual);
    double expectedMag = abs(expected);
    
    if (!isRelativelyEqual(actualMag, expectedMag, tolerance)) {
        return false;
    }
    
    // Only compare phase if magnitude is not near zero
    if (expectedMag > 1e-10) {
        double actualPhase = arg(actual);
        double expectedPhase = arg(expected);
        return isRelativelyEqual(actualPhase, expectedPhase, tolerance);
    }
    return true;
}

/**
 * Helper to create an NgspiceServer instance for testing.
 * 
 * Returns: A configured NgspiceServer instance
 */
private NgspiceServer createTestServer() {
    const int DEFAULT_MAX_POINTS = 1000;
    const string TEST_WORKING_DIR = ".";  // Current directory for tests
    
    return new NgspiceServer(
        DEFAULT_MAX_POINTS,
        TEST_WORKING_DIR
    );
}

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
    auto server = createTestServer();
    
    try {
        // Test loading from file
        auto result = server.executeTool("loadNetlistFromFile", ["filepath": filename].serializeToJson());
        assert(result["status"].str == "Circuit loaded and simulation run successfully", 
            "Failed to load valid netlist file");
    } catch (Exception e) {
        assert(false, "Exception thrown for valid netlist: " ~ e.msg);
    }
}

@("loadNetlistFromFile with non-existent file")
unittest {
    auto server = createTestServer();
    
    // Test with non-existent file
    assertThrown!MCPError(
        server.executeTool("loadNetlistFromFile", ["filepath": "nonexistent.sp"].serializeToJson()),
        "Failed to throw error for non-existent file"
    );
}

@("loadNetlistFromFile with empty file")
unittest {
    // Create empty test file
    string filename = createTempNetlist("");
    scope(exit) if (exists(filename)) remove(filename);

    auto server = createTestServer();
    
    // Test with empty file
    assertThrown!MCPError(
        server.executeTool("loadNetlistFromFile", ["filepath": filename].serializeToJson()),
        "Failed to throw error for empty file"
    );
}

@("getVectorData interpolation")
unittest {
    auto server = createTestServer();

    // Load a test circuit
    string testCircuit = "Test RC\nv1 in 0 sin(0 1 1k)\nR1 in out 1k\nC1 out 0 1u\n.tran 1u 1m\n.end";
    server.executeTool("loadCircuit", ["netlist": testCircuit].serializeToJson());

    // Get scale values
    double[] points = [0.0, 0.5e-3, 1.0e-3];  // Points at 0, 0.5ms, and 1ms
    
    // Test interpolation
    JSONValue[string] args;
    args["vectors"] = JSONValue(["out"]);
    args["points"] = JSONValue(points);
    args["plot"] = JSONValue("tran1");
    auto result = server.executeTool("getVectorData", JSONValue(args));

    assert("vectors" in result, "Missing vectors in result");
    assert("out" in result["vectors"].object, "Missing vector data");
    
    auto vectorResult = result["vectors"]["out"];
    assert("data" in vectorResult, "Missing data field");
    assert("points" in vectorResult, "Missing points field");
    
    assert(vectorResult["data"].array.length == points.length, "Incorrect data length");
    
    // Verify returned points match requested points
    foreach (i, point; points) {
        auto pointValue = vectorResult["points"][i].get!double;
        assert(isRelativelyEqual(pointValue, point),
            format!"Interpolation point mismatch at index %d"(i));
    }
}

@("getVectorData with complex scales")
unittest {
    auto server = createTestServer();

    // Test complex scale types with various circuit configurations
    string[] testCircuits = [
        // Basic AC analysis
        "Test RC\nv1 in 0 ac 1\nR1 in out 1k\nC1 out 0 1u\n.ac dec 10 1k 100k\n.end",
        
        // Multiple frequency points
        "Test RC\nv1 in 0 ac 1\nR1 in out 1k\nC1 out 0 1u\n.ac lin 20 1k 100k\n.end",
        
        // Circuit with multiple nodes
        "Test RLC\nv1 in 0 ac 1\nL1 in n1 1m\nR1 n1 out 1k\nC1 out 0 1u\n.ac dec 10 1k 100k\n.end"
    ];

    foreach (testCircuit; testCircuits) {
        // Load circuit and run simulation
        server.executeTool("loadCircuit", ["netlist": testCircuit].serializeToJson());

        // Test points at various frequencies
        double[] points = [1e3, 5e3, 10e3, 50e3, 100e3];  // Multiple frequency points
        
        // Test all representation formats
        string[] formats = ["rectangular", "magnitude-phase", "both"];
        foreach (format; formats) {
            JSONValue[string] args;
            args["vectors"] = JSONValue(["out"]);
            args["points"] = JSONValue(points);
            args["plot"] = JSONValue("ac1");
            args["representation"] = JSONValue(format);
            auto result = server.executeTool("getVectorData", JSONValue(args));

            auto vectorResult = result["vectors"]["out"];
            assert(vectorResult["data"].array.length == points.length);
            
            // Verify data format
            foreach (dataPoint; vectorResult["data"].array) {
                if (format == "rectangular" || format == "both") {
                    assert("real" in dataPoint, "Missing real component");
                    assert("imag" in dataPoint, "Missing imaginary component");
                }
                if (format == "magnitude-phase" || format == "both") {
                    assert("magnitude" in dataPoint, "Missing magnitude");
                    assert("phase" in dataPoint, "Missing phase");
                }

                // Verify value consistency if format is "both"
                if (format == "both") {
                    import std.math : abs, PI;
                    double realPart = dataPoint["real"].get!double;
                    double imagPart = dataPoint["imag"].get!double;
                    double mag = dataPoint["magnitude"].get!double;
                    double phase = dataPoint["phase"].get!double * (PI/180.0); // Convert to radians
                    
                    // Verify consistency between rectangular and polar forms
                    auto rectangular = Complex!double(realPart, imagPart);
                    auto polar = Complex!double(mag * cos(phase), mag * sin(phase));
                    assert(isRelativelyEqual(rectangular, polar),
                        "Complex representations are inconsistent");
                }
            }

            // Verify scale points
            foreach (i, point; vectorResult["points"].array) {
                // For AC analysis, scale points should be real numbers
                    assert(isRelativelyEqual(point.get!double, points[i]));
            }
        }
    }
}

@("getVectorData interpolation accuracy")
unittest {
    auto server = createTestServer();

    // Load a test circuit with known analytic solution
    string testCircuit = q"[
        * RC filter with known frequency response
        v1 in 0 ac 1
        R1 in out 1k
        C1 out 0 1u
        .ac dec 10 1k 100k
        .end
    ]";
    server.executeTool("loadCircuit", ["netlist": testCircuit].serializeToJson());

    // Test interpolation at specific frequencies
    double[] points = [2e3, 15e3, 75e3];  // Points between simulation points
    
    JSONValue[string] args;
    args["vectors"] = JSONValue(["out"]);
    args["points"] = JSONValue(points);
    args["plot"] = JSONValue("ac4");
    args["representation"] = JSONValue("both");
    debug { import std.stdio : writeln; writeln(server.executeTool("getPlotNames", JSONValue.emptyObject).toPrettyString); }
    auto result = server.executeTool("getVectorData", JSONValue(args));

    auto vectorResult = result["vectors"]["out"];
    
    // Verify interpolation accuracy against analytical solution
    foreach (i, point; vectorResult["data"].array) {
        double f = points[i];
        double w = 2 * PI * f;
        double R = 1000;  // 1k ohm
        double C = 1e-6;  // 1uF
        
        // Calculate expected magnitude and phase
        double expectedMag = 1.0 / sqrt(1 + (w*R*C)*(w*R*C));
        double expectedPhase = -atan2(w*R*C, 1.0) * 180.0/PI;  // Convert to degrees
        
        // Get actual values
        double actualMag = point["magnitude"].get!double;
        double actualPhase = point["phase"].get!double;
        
        // Verify magnitude and phase within tolerance
        assert(isRelativelyEqual(actualMag, expectedMag),
            format!"Magnitude interpolation error at %g Hz: expected %g, got %g"(
                f, expectedMag, actualMag));
        
        assert(isRelativelyEqual(actualPhase, expectedPhase),
            format!"Phase interpolation error at %g Hz: expected %g, got %g"(
                f, expectedPhase, actualPhase));
    }
}

@("getVectorData with complex values")
unittest {
    auto server = createTestServer();

    // Load a test circuit with AC analysis
    string testCircuit = "Test RC\nv1 in 0 ac 1\nR1 in out 1k\nC1 out 0 1u\n.ac dec 10 1k 100k\n.end";
    server.executeTool("loadCircuit", ["netlist": testCircuit].serializeToJson());
    debug { import std.stdio : writeln; writeln(server.executeTool("getPlotNames", JSONValue.emptyObject).toPrettyString); }

    // Test points at specific frequencies
    double[] points = [1e3, 10e3, 100e3];  // 1kHz, 10kHz, 100kHz
    
    // Test rectangular representation
    JSONValue[string] args;
    args["vectors"] = JSONValue(["out"]);
    args["points"] = JSONValue(points);
    args["plot"] = JSONValue("ac5");
    args["representation"] = JSONValue("rectangular");
    auto result = server.executeTool("getVectorData", JSONValue(args));

    auto vectorResult = result["vectors"]["out"];
    assert(vectorResult["data"].array.length == points.length, "Incorrect data length");
    
    // Verify each point has real and imaginary components
    foreach (dataPoint; vectorResult["data"].array) {
        assert("real" in dataPoint, "Missing real component");
        assert("imag" in dataPoint, "Missing imaginary component");
    }

    // Test magnitude-phase representation
    args["representation"] = JSONValue("magnitude-phase");
    result = server.executeTool("getVectorData", JSONValue(args));

    vectorResult = result["vectors"]["out"];
    
    // Verify each point has magnitude and phase
    foreach (dataPoint; vectorResult["data"].array) {
        assert("magnitude" in dataPoint, "Missing magnitude");
        assert("phase" in dataPoint, "Missing phase");
    }
}

@("getVectorData with out of range points")
unittest {
    auto server = createTestServer();

    // Load a test circuit
    string testCircuit = "Test RC\nv1 in 0 sin(0 1 1k)\nR1 in out 1k\nC1 out 0 1u\n.tran 1u 1m\n.end";
    server.executeTool("loadCircuit", ["netlist": testCircuit].serializeToJson());
    debug { import std.stdio : writeln; writeln(server.executeTool("getPlotNames", JSONValue.emptyObject).toPrettyString); }

    // Get the simulation time range
    auto infoResult = server.executeTool("getVectorsInfo", ["plot": "tran5"].serializeToJson());
    string timeName;
    double minTime = double.infinity;
    double maxTime = -double.infinity;

    foreach (vector; infoResult["vectors"].array) {
        if (vector["type"].str == "time") {
            timeName = vector["name"].str;
            minTime = vector["range"]["min"].get!double;
            maxTime = vector["range"]["max"].get!double;
            break;
        }
    }

    // Test points outside simulation range
    double beforeStart = minTime - 1e-3;  // Point before simulation start
    double middle = (minTime + maxTime) / 2;  // Valid middle point
    double afterEnd = maxTime + 1e-3;  // Point after simulation end
    
    JSONValue[string] args;
    args["vectors"] = JSONValue(["out"]);
    args["points"] = JSONValue([beforeStart, middle, afterEnd]);
    args["plot"] = JSONValue("tran5");
    auto result = server.executeTool("getVectorData", JSONValue(args));

    auto vectorResult = result["vectors"]["out"];
    assert(!("data" in vectorResult), "Should not have data field for failed interpolation");
    assert("error" in vectorResult, "Missing error field in result");
    assert(vectorResult["error"].str.indexOf("outside interpolation domain") >= 0, 
        "Error message should indicate domain violation");
}

@("getLocalExtrema basics")
unittest {
    auto server = createTestServer();

    // Load a test circuit with sinusoidal input
    string testCircuit = q"[
        Test RC
        v1 in 0 sin(0 1 1k)
        R1 in out 1k
        C1 out 0 1u
        .tran 1u 1m
        .end
    ]";
    server.executeTool("loadCircuit", ["netlist": testCircuit].serializeToJson());

    // Test finding extrema
    JSONValue[string] options;
    options["threshold"] = JSONValue(0.1);
    
    JSONValue[string] args;
    args["vectors"] = JSONValue(["v(out)"]);
    args["plot"] = JSONValue("tran1");
    args["options"] = JSONValue(options);
    auto result = server.executeTool("getLocalExtrema", JSONValue(args));

    assert("vectors" in result);
    auto vectorData = result["vectors"]["v(out)"];
    
    // Check that we have the vector length, maxima and minima
    assert("length" in vectorData);
    assert("maxima" in vectorData);
    assert("minima" in vectorData);

    // Each point should have index, value, and scale
    foreach (point; vectorData["maxima"].array) {
        assert("index" in point);
        assert("value" in point);
        assert("scale" in point);
    }

    foreach (point; vectorData["minima"].array) {
        assert("index" in point);
        assert("value" in point);
        assert("scale" in point);
    }
}

@("getVectorsInfo returns scale information")
unittest {
    auto server = createTestServer();

    // Load a test circuit with transient analysis
    string testCircuit = "Test RC\nv1 in 0 sin(0 1 1k)\nR1 in out 1k\nC1 out 0 1u\n.tran 1u 1m\n.end";
    server.executeTool("loadCircuit", ["netlist": testCircuit].serializeToJson());

    // Test getVectorsInfo
    JSONValue[string] args;
    args["plot"] = JSONValue("tran1");
    auto result = server.executeTool("getVectorsInfo", JSONValue(args));
    
    // Verify result structure
    assert("vectors" in result, "Missing vectors in result");
    assert(result["vectors"].array.length > 0, "No vectors returned");
    
    // Check v(out) vector
    bool foundVout = false;
    foreach (vector; result["vectors"].array) {
        if (vector["name"].str.endsWith("v(out)")) {
            foundVout = true;
            
            // Verify vector structure
            assert("isReal" in vector, "Missing isReal flag");
            assert("range" in vector, "Missing range info");
            assert("scale" in vector, "Missing scale info");
            
            // Check range information
            auto range = vector["range"];
            assert("min" in range, "Missing min value in range");
            assert("max" in range, "Missing max value in range");
            
            // Check scale information
            auto scale = vector["scale"];
            assert("name" in scale, "Missing scale name");
            assert("type" in scale, "Missing scale type");
            assert(scale["type"].str == "time", "Incorrect scale type for transient analysis");
            
            break;
        }
    }
    assert(foundVout, "v(out) vector not found in results");
}

@("getVectorsInfo with AC analysis")
unittest {
    auto server = createTestServer();

    // Load a test circuit with AC analysis
    string testCircuit = "Test RC\nv1 in 0 ac 1\nR1 in out 1k\nC1 out 0 1u\n.ac dec 10 1k 100k\n.end";
    server.executeTool("loadCircuit", ["netlist": testCircuit].serializeToJson());

    // Test getVectorsInfo
    JSONValue[string] args;
    args["plot"] = JSONValue("ac1");
    auto result = server.executeTool("getVectorsInfo", JSONValue(args));
    
    // Verify result structure
    assert("vectors" in result, "Missing vectors in result");
    assert(result["vectors"].array.length > 0, "No vectors returned");
    
    // Find the output voltage vector
    bool foundVout = false;
    foreach (vector; result["vectors"].array) {
        if (vector["name"].str.endsWith("v(out)")) {
            foundVout = true;
            
            // Verify vector structure
            assert("isReal" in vector, "Missing isReal flag");
            assert(!vector["isReal"].boolean, "AC analysis should have complex data");
            
            // Check range information (should use magnitudes for complex data)
            assert("range" in vector, "Missing range info");
            auto range = vector["range"];
            assert("min" in range, "Missing min value in range");
            assert("max" in range, "Missing max value in range");
            
            // Check scale information
            assert("scale" in vector, "Missing scale info");
            auto scale = vector["scale"];
            assert("name" in scale, "Missing scale name");
            assert("type" in scale, "Missing scale type");
            assert(scale["type"].str == "frequency", "Incorrect scale type for AC analysis");
            
            break;
        }
    }
    assert(foundVout, "v(out) vector not found in results");
}

@("getVectorData with out of range complex scales")
unittest {
    auto server = createTestServer();

    // Load a test circuit with AC analysis
    string testCircuit = "Test RC\nv1 in 0 ac 1\nR1 in out 1k\nC1 out 0 1u\n.ac dec 10 1k 100k\n.end";
    server.executeTool("loadCircuit", ["netlist": testCircuit].serializeToJson());

    // Get the frequency range
    auto infoResult = server.executeTool("getVectorsInfo", ["plot": "ac1"].serializeToJson());
    double minFreq = double.infinity;
    double maxFreq = -double.infinity;

    foreach (vector; infoResult["vectors"].array) {
        if (vector["type"].str == "frequency") {
            minFreq = vector["range"]["min"].get!double;
            maxFreq = vector["range"]["max"].get!double;
            break;
        }
    }

    // Test points outside frequency range
    double beforeStart = minFreq / 2;  // Point before start frequency
    double middle = sqrt(minFreq * maxFreq);  // Valid middle frequency
    double afterEnd = maxFreq * 2;  // Point after end frequency
    
    JSONValue[string] args;
    args["vectors"] = JSONValue(["out"]);
    args["points"] = JSONValue([beforeStart, middle, afterEnd]);
    args["plot"] = JSONValue("ac1");
    args["representation"] = JSONValue("magnitude-phase");
    auto result = server.executeTool("getVectorData", JSONValue(args));

    auto vectorResult = result["vectors"]["out"];
    assert(!("data" in vectorResult), "Should not have data field for failed interpolation");
    assert("error" in vectorResult, "Missing error field in result");
    assert(vectorResult["error"].str.indexOf("outside interpolation domain") >= 0, 
        "Error message should indicate domain violation");
}

@("plot listing functionality")
unittest {
    auto server = createTestServer();

    // Test initial state (no plots)
    auto result = server.executeTool("getPlotNames", JSONValue.emptyObject);
    assert("plots" in result, "Missing plots field in response");
    assert(result["plots"].array.length == 0, "Should have no plots initially");

    // Load a circuit with transient analysis
    string transientCircuit = "Test RC\nv1 in 0 sin(0 1 1k)\nR1 in out 1k\nC1 out 0 1u\n.tran 1u 1m\n.end";
    server.executeTool("loadCircuit", ["netlist": transientCircuit].serializeToJson());

    // Check plots after transient analysis
    result = server.executeTool("getPlotNames", JSONValue.emptyObject);
    assert(result["plots"].array.length > 0, "No plots after loading circuit");
    bool foundTran = false;
    foreach (plot; result["plots"].array) {
        if (plot.str.startsWith("tran")) {
            foundTran = true;
            break;
        }
    }
    assert(foundTran, "Missing transient analysis plot");

    // Load a circuit with AC analysis
    string acCircuit = "Test RC\nv1 in 0 ac 1\nR1 in out 1k\nC1 out 0 1u\n.ac dec 10 1k 100k\n.end";
    server.executeTool("loadCircuit", ["netlist": acCircuit].serializeToJson());

    // Check plots after AC analysis
    result = server.executeTool("getPlotNames", JSONValue.emptyObject);
    assert(result["plots"].array.length > 0, "No plots after loading circuit");
    bool foundAc = false;
    foreach (plot; result["plots"].array) {
        if (plot.str.startsWith("ac")) {
            foundAc = true;
            break;
        }
    }
    assert(foundAc, "Missing AC analysis plot");

    // Verify integration with loadCircuit response
    auto loadResult = server.executeTool("loadCircuit", ["netlist": acCircuit].serializeToJson());
    assert("plots" in loadResult, "Missing plots field in loadCircuit response");
    assert(loadResult["plots"].array.length > 0, "No plots in loadCircuit response");

    // Verify integration with runSimulation response
    JSONValue[string] simArgs;
    simArgs["command"] = JSONValue("tran 1u 1m");
    auto simResult = server.executeTool("runSimulation", JSONValue(simArgs));
    assert("plots" in simResult, "Missing plots field in runSimulation response");
    assert(simResult["plots"].array.length > 0, "No plots in runSimulation response");
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

    auto server = createTestServer();

    foreach (netlist; validNetlists) {
        string filename = createTempNetlist(netlist);
        scope(exit) if (exists(filename)) remove(filename);

        try {
            auto result = server.executeTool("loadNetlistFromFile", ["filepath": filename].serializeToJson());
            assert(result["status"].str == "Circuit loaded and simulation run successfully",
                "Failed to load valid netlist variant");
        } catch (Exception e) {
            assert(false, "Exception thrown for valid netlist variant: " ~ e.msg);
        }
    }
}
