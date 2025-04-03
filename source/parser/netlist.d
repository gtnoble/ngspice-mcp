module parser.netlist;

import std.stdio;
import std.string;
import std.regex;
import std.algorithm;
import std.array;
import std.conv;
import std.typecons : Nullable;
import database.queries;

private immutable string[] spiceFunctions = [
    "abs", "acos", "acosh", "asin", "asinh", 
    "atan", "atanh", "cos", "cosh", "exp", 
    "ln", "log", "log10", "max", "min", 
    "pow", "pwr", "sin", "sinh", "sqrt", 
    "tan", "tanh", "uramp", "ceil", "floor", 
    "nint", "sgn", "buf", "inv", "table"
];

/// Netlist line with source information
struct NetlistLine {
    string content;
    size_t lineNumber;
    string sourceFile;
}

/// Netlist parser for extracting models and subcircuits
class NetlistParser {
    private {
        File logFile;
        bool logging = false;
    }

    this(string logPath = null) {
        if (logPath) {
            logFile = File(logPath, "w");
            logging = true;
        }
    }

    ~this() {
        if (logging) {
            logFile.close();
        }
    }

    private void log(string message) {
        if (logging) {
            logFile.writeln(message);
            logFile.flush();
        }
    }

    private void logSkippedParameter(string modelName, string paramName, string value, string reason) {
        log("Skipping parameter in model '%s': %s = %s (Reason: %s)".format(
            modelName, paramName, value, reason));
    }

    /// Parse a netlist file and extract models and subcircuits
    void parseFile(string filename, DatabaseQueries queries) {
        auto lines = File(filename, "r")
            .byLine
            .map!(l => NetlistLine(l.strip.idup, 0, filename))
            .array;

        foreach (ref line; lines) {
            if (line.content.startsWith(".model")) {
                parseModel(line, queries);
            }
            else if (line.content.startsWith(".subckt")) {
                parseSubcircuit(line, lines, queries);
            }
        }
    }

    private bool shouldSkipParameter(string value) {
        // Check for expression operators
        if (value.canFind(['(', ')', '+', '-', '*', '/', ','])) {
            return true;
        }

        // Check for any word followed by parenthesis (function call)
        if (value.matchFirst(r"\w+\s*\(")) {
            return true;
        }

        // Check for SPICE functions
        foreach (func; spiceFunctions) {
            if (value.matchFirst(regex("^" ~ func ~ r"\s*[\(\s]"))) {
                return true;
            }
        }

        return false;
    }

    private ParameterValue processParameterValue(string name, string value) {
        if (shouldSkipParameter(value)) {
            return ParameterValue(value, ParamType.STRING, Nullable!double.init);
        }

        // Try parsing as numeric value
        try {
            // Handle SI prefixes
            double multiplier = 1.0;
            if (value.length > 0) {
                char lastChar = value[$-1];
                string numPart = value;
                
                switch (lastChar) {
                    case 'T': multiplier = 1e12; numPart = value[0..$-1]; break;
                    case 'G': multiplier = 1e9;  numPart = value[0..$-1]; break;
                    case 'M': multiplier = 1e6;  numPart = value[0..$-1]; break;
                    case 'k': multiplier = 1e3;  numPart = value[0..$-1]; break;
                    case 'm': multiplier = 1e-3; numPart = value[0..$-1]; break;
                    case 'u': multiplier = 1e-6; numPart = value[0..$-1]; break;
                    case 'n': multiplier = 1e-9; numPart = value[0..$-1]; break;
                    case 'p': multiplier = 1e-12; numPart = value[0..$-1]; break;
                    default: break;
                }

                if (auto numericValue = parse!double(numPart)) {
                    return ParameterValue(
                        value,
                        ParamType.NUMERIC,
                        Nullable!double(numericValue * multiplier)
                    );
                }
            }
        } catch (Exception e) {
            // If parsing fails, treat as string
        }

        return ParameterValue(value, ParamType.STRING, Nullable!double.init);
    }

    private void parseModel(NetlistLine line, DatabaseQueries queries) {
        auto parts = line.content.split();
        if (parts.length < 3) {
            log("Invalid model definition at %s:%d: %s".format(
                line.sourceFile, line.lineNumber, line.content));
            return;
        }

        string modelName = parts[1];
        string modelType = parts[2].toLower;
        
        // Parse parameters
        ParameterValue[string] parameters;
        if (parts.length > 3) {
            string paramString = parts[3..$].join(" ");
            auto paramPairs = paramString.matchAll(`[^\s"']+|"([^"]*)"|'([^']*)'`);
            
            foreach (pair; paramPairs) {
                if (pair.hit.canFind('=')) {
                    auto keyValue = pair.hit.split('=');
                    if (keyValue.length == 2) {
                        string paramName = keyValue[0].strip;
                        string paramValue = keyValue[1].strip;
                        
                        if (shouldSkipParameter(paramValue)) {
                            logSkippedParameter(modelName, paramName, paramValue, 
                                "Contains expression or function");
                            parameters[paramName] = ParameterValue(
                                paramValue, ParamType.STRING, Nullable!double.init);
                        } else {
                            parameters[paramName] = processParameterValue(paramName, paramValue);
                        }
                    }
                }
            }
        }

        // Insert model into database
        auto modelData = ModelData(
            modelName,
            modelType,
            line.sourceFile,
            line.lineNumber,
            parameters
        );

        queries.insertModel(modelData);
    }

    private void parseSubcircuit(NetlistLine line, NetlistLine[] allLines, DatabaseQueries queries) {
        auto parts = line.content.split();
        if (parts.length < 2) {
            log("Invalid subcircuit definition at %s:%d: %s".format(
                line.sourceFile, line.lineNumber, line.content));
            return;
        }

        string subcktName = parts[1];
        size_t startLine = line.lineNumber;
        string content = line.content ~ "\n";
        
        // Find matching .ends
        size_t endLine = startLine;
        size_t nesting = 1;
        
        foreach (ref subcktLine; allLines[startLine + 1 .. $]) {
            if (subcktLine.content.startsWith(".subckt")) {
                nesting++;
            }
            else if (subcktLine.content.startsWith(".ends")) {
                nesting--;
                if (nesting == 0) {
                    endLine = subcktLine.lineNumber;
                    content ~= subcktLine.content;
                    break;
                }
            }
            content ~= subcktLine.content ~ "\n";
        }

        if (nesting > 0) {
            log("Unclosed subcircuit definition starting at %s:%d".format(
                line.sourceFile, startLine));
            return;
        }

        // Insert subcircuit into database
        auto subcktData = SubcircuitData(
            subcktName,
            content,
            line.sourceFile,
            startLine
        );

        queries.insertSubcircuit(subcktData);
    }
}

version(unittest) {
    import std.file : tempDir;
    import std.path : buildPath;
    import database.schema : createTestDatabase;

    unittest {
        // Create test database and parser
        auto dbPool = createTestDatabase();
        auto queries = new DatabaseQueries(dbPool.getConnection());
        auto parser = new NetlistParser();

        // Test model parsing
        auto testLine = NetlistLine(
            ".model test_nmos nmos l=0.18u w=1u vth=0.7 tox=1.4e-8",
            1,
            "test.sp"
        );

        parser.parseModel(testLine, queries);

        // Query and verify
        auto filter = ModelFilter("nmos", null, null, 10);
        auto results = queries.queryModels(filter);
        
        assert(results.length == 1);
        assert("test_nmos" in results);
        assert("l" in results["test_nmos"].parameters);
        assert("w" in results["test_nmos"].parameters);
        assert("vth" in results["test_nmos"].parameters);
        assert("tox" in results["test_nmos"].parameters);
    }
}
