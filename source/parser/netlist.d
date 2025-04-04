module parser.netlist;

import std.stdio;
import std.string;
import std.regex;
import std.algorithm;
import std.array;
import std.conv;
import std.typecons : Nullable;
import std.file : readText;
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

/// Token types for the lexer
private enum TokenType {
    DOT_COMMAND,    // .model, .subckt, .ends, etc.
    IDENTIFIER,     // Names, types
    EQUALS,         // =
    NUMBER,         // Numeric values without suffixes
    SI_SUFFIX,      // p, n, u, m, k, M, G, T, meg
    OPERATOR,       // +, -, *, /, etc.
    LPAREN,         // (
    RPAREN,         // )
    COMMA,          // ,
    QUOTE,          // ' or "
    STRING,         // Quoted string
    VALUE,          // Generic parameter value (for backward compatibility)
    NEWLINE,        // End of line
    EOF,            // End of file
    UNKNOWN         // Unrecognized token
}

/// Token structure for the lexer
private struct Token {
    TokenType type;
    string value;
    size_t line;
    string sourceFile;
}

/// Lexer for tokenizing SPICE netlist files
private class Lexer {
    private {
        string input;
        size_t position;
        size_t currentLine;
        string sourceFile;
        char[] currentLineContent;
        size_t lineStartPosition;
    }
    
    this(string input, string sourceFile) {
        this.input = input;
        this.sourceFile = sourceFile;
        this.currentLine = 1;
        this.position = 0;
        this.lineStartPosition = 0;
        this.currentLineContent = [];
    }
    
    Token nextToken() {
        // Skip whitespace
        skipWhitespace();
        
        // Check for EOF
        if (position >= input.length) {
            return Token(TokenType.EOF, "", currentLine, sourceFile);
        }
        
        // Check for newline
        if (input[position] == '\n') {
            position++;
            currentLine++;
            lineStartPosition = position;
            currentLineContent = [];
            return Token(TokenType.NEWLINE, "\n", currentLine - 1, sourceFile);
        }
        
        // Capture current character for line content
        if (position >= lineStartPosition) {
            if (currentLineContent.length == 0) {
                currentLineContent = input[lineStartPosition..position].dup;
            }
            currentLineContent ~= input[position];
        }
        
        // Check for different token types
        if (input[position] == '.') {
            return readDotCommand();
        } else if (isAlphaOrUnderscore(input[position])) {
            return readIdentifier();
        } else if (input[position] == '=') {
            position++;
            return Token(TokenType.EQUALS, "=", currentLine, sourceFile);
        } else if (input[position] == '(') {
            position++;
            return Token(TokenType.LPAREN, "(", currentLine, sourceFile);
        } else if (input[position] == ')') {
            position++;
            return Token(TokenType.RPAREN, ")", currentLine, sourceFile);
        } else if (isValueStart(input[position])) {
            return readValue();
        } else {
            // Unknown token
            char c = input[position];
            position++;
            return Token(TokenType.UNKNOWN, [c], currentLine, sourceFile);
        }
    }
    
    private Token readDotCommand() {
        size_t start = position;
        position++; // Skip the dot
        
        // Read until whitespace or end of input
        while (position < input.length && !isWhitespace(input[position])) {
            position++;
        }
        
        string command = input[start..position];
        return Token(TokenType.DOT_COMMAND, command, currentLine, sourceFile);
    }
    
    private Token readIdentifier() {
        size_t start = position;
        
        // Read until non-alphanumeric or end of input
        while (position < input.length && 
               (isAlphaNumeric(input[position]) || input[position] == '_')) {
            position++;
        }
        
        string identifier = input[start..position];
        return Token(TokenType.IDENTIFIER, identifier, currentLine, sourceFile);
    }
    
    private Token readValue() {
        // Check if it's a quoted string
        if (input[position] == '\'' || input[position] == '"') {
            return readString();
        }
        
        // Check if it's a number
        if (isDigit(input[position]) || 
            (input[position] == '.' && position + 1 < input.length && isDigit(input[position + 1])) ||
            ((input[position] == '+' || input[position] == '-') && 
             position + 1 < input.length && 
             (isDigit(input[position + 1]) || 
              (input[position + 1] == '.' && position + 2 < input.length && isDigit(input[position + 2]))))) {
            return readNumber();
        }
        
        // Check if it's an operator
        if (input[position] == '+' || input[position] == '-' || 
            input[position] == '*' || input[position] == '/' || 
            input[position] == '^') {
            char op = input[position];
            position++;
            return Token(TokenType.OPERATOR, [op], currentLine, sourceFile);
        }
        
        // Check if it's a comma
        if (input[position] == ',') {
            position++;
            return Token(TokenType.COMMA, ",", currentLine, sourceFile);
        }
        
        // Generic value (for backward compatibility)
        size_t start = position;
        
        // Read until whitespace, equals, parenthesis, comma, or end of input
        while (position < input.length && 
               !isWhitespace(input[position]) && 
               input[position] != '=' && 
               input[position] != '(' && 
               input[position] != ')' &&
               input[position] != ',') {
            position++;
        }
        
        string value = input[start..position];
        return Token(TokenType.VALUE, value, currentLine, sourceFile);
    }
    
    private Token readString() {
        char quote = input[position];
        position++; // Skip opening quote
        
        size_t start = position;
        
        // Read until closing quote or end of input
        while (position < input.length && input[position] != quote) {
            position++;
        }
        
        string content = input[start..position];
        
        if (position < input.length) {
            position++; // Skip closing quote
        }
        
        return Token(TokenType.STRING, content, currentLine, sourceFile);
    }
    
    private Token readNumber() {
        size_t start = position;
        
        // Handle sign
        if (input[position] == '+' || input[position] == '-') {
            position++;
        }
        
        // Read digits before decimal point
        while (position < input.length && isDigit(input[position])) {
            position++;
        }
        
        // Read decimal point and digits after
        if (position < input.length && input[position] == '.') {
            position++;
            while (position < input.length && isDigit(input[position])) {
                position++;
            }
        }
        
        // Read exponent (e or E followed by optional sign and digits)
        if (position < input.length && (input[position] == 'e' || input[position] == 'E')) {
            position++;
            if (position < input.length && (input[position] == '+' || input[position] == '-')) {
                position++;
            }
            while (position < input.length && isDigit(input[position])) {
                position++;
            }
        }
        
        // Check for SI suffix
        if (position < input.length) {
            // Check for "meg" suffix
            if (position + 2 < input.length && 
                toLower(input[position]) == 'm' && 
                toLower(input[position+1]) == 'e' && 
                toLower(input[position+2]) == 'g') {
                string number = input[start..position];
                string suffix = input[position..position+3];
                position += 3; // Consume "meg"
                return Token(TokenType.NUMBER, number, currentLine, sourceFile);
            }
            
            // Check for single-character suffixes
            char c = toLower(input[position]);
            if (c == 'p' || c == 'n' || c == 'u' || c == 'm' || 
                c == 'k' || c == 'g' || c == 't') {
                string number = input[start..position];
                string suffix = [input[position]];
                position++; // Consume the suffix
                return Token(TokenType.NUMBER, number, currentLine, sourceFile);
            }
        }
        
        string number = input[start..position];
        return Token(TokenType.NUMBER, number, currentLine, sourceFile);
    }
    
    private bool isDigit(char c) {
        return c >= '0' && c <= '9';
    }
    
    private char toLower(char c) {
        return (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
    }
    
    private void skipWhitespace() {
        while (position < input.length && 
               (input[position] == ' ' || input[position] == '\t' || input[position] == '\r')) {
            position++;
        }
    }
    
    private bool isWhitespace(char c) {
        return c == ' ' || c == '\t' || c == '\n' || c == '\r';
    }
    
    private bool isAlphaOrUnderscore(char c) {
        return (c >= 'a' && c <= 'z') || 
               (c >= 'A' && c <= 'Z') || 
               c == '_';
    }
    
    private bool isAlphaNumeric(char c) {
        return isAlphaOrUnderscore(c) || (c >= '0' && c <= '9');
    }
    
    private bool isValueStart(char c) {
        return (c >= '0' && c <= '9') || 
               c == '+' || c == '-' || 
               c == '.' || c == '\'' || c == '"' ||
               c == ',' || c == '*' || c == '/' || c == '^';
    }
    
    string getCurrentLine() {
        if (currentLineContent.length > 0) {
            return currentLineContent.idup;
        }
        
        // Find the end of the current line
        size_t end = position;
        while (end < input.length && input[end] != '\n') {
            end++;
        }
        
        return input[lineStartPosition..end];
    }
}

/// Recursive descent parser for SPICE netlists
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
        // Read the entire file content
        string content = readText(filename).toLower(); // Case normalization at source
        
        // Create a parser and process the file
        auto parser = new Parser(content, filename, queries, this);
        parser.parse();
    }

    private bool containsExpressions(string paramString) {
        // Check for expression operators
        if (paramString.canFind(['(', ')', '+', '-', '*', '/', ','])) {
            return true;
        }

        // Check for any word followed by parenthesis (function call)
        if (paramString.matchFirst(r"\w+\s*\(")) {
            return true;
        }

        // Check for SPICE functions
        foreach (func; spiceFunctions) {
            if (paramString.matchFirst(regex("^" ~ func ~ r"\s*[\(\s]"))) {
                return true;
            }
        }

        return false;
    }

    private bool shouldSkipParameter(string value) {
        return containsExpressions(value);
    }

    private ParameterValue processParameterValue(string name, string value) {
        if (shouldSkipParameter(value)) {
            return ParameterValue(value, ParamType.STRING, Nullable!double.init);
        }

        // Try parsing as numeric value
        try {
            // Handle SI prefixes
            string numPart = value;
            double multiplier = 1.0;

            // Handle suffixes and multipliers
            if (value.length > 0) {
                if (value.toLower.endsWith("meg")) {
                    multiplier = 1e6;
                    numPart = value[0..$-3];
                }
                else {
                    // Check single character suffixes
                    char lastChar = value[$-1];
                    switch (lastChar) {
                        case 't': multiplier = 1e12; numPart = value[0..$-1]; break;
                        case 'g': multiplier = 1e9;  numPart = value[0..$-1]; break;
                        case 'k': multiplier = 1e3;  numPart = value[0..$-1]; break;
                        case 'm': multiplier = 1e-3; numPart = value[0..$-1]; break;
                        case 'u': multiplier = 1e-6; numPart = value[0..$-1]; break;
                        case 'n': multiplier = 1e-9; numPart = value[0..$-1]; break;
                        case 'p': multiplier = 1e-12; numPart = value[0..$-1]; break;
                        default: break;
                    }
                }
            }

            // Try to parse the numeric part
            double baseValue = parse!double(numPart);
            return ParameterValue(
                value,
                ParamType.NUMERIC,
                Nullable!double(baseValue * multiplier)
            );

        } catch (Exception e) {
            // If parsing fails, treat as string
        }

        return ParameterValue(value, ParamType.STRING, Nullable!double.init);
    }
}

/// Parser implementation using recursive descent
private class Parser {
    private {
        Lexer lexer;
        Token currentToken;
        DatabaseQueries queries;
        NetlistParser parent;
        bool atTopLevel = true;
    }
    
    this(string input, string sourceFile, DatabaseQueries queries, NetlistParser parent) {
        this.lexer = new Lexer(input, sourceFile);
        this.queries = queries;
        this.parent = parent;
        this.currentToken = lexer.nextToken();
    }
    
    void parse() {
        while (currentToken.type != TokenType.EOF) {
            if (currentToken.type == TokenType.DOT_COMMAND) {
                if (currentToken.value == ".model") {
                    if (atTopLevel) {
                        parseModel();
                    } else {
                        parent.log("Skipping model definition inside subcircuit at %s:%d: %s".format(
                            currentToken.sourceFile, currentToken.line, lexer.getCurrentLine()));
                        skipToNextLine();
                    }
                } else if (currentToken.value == ".subckt") {
                    if (atTopLevel) {
                        parseSubcircuit();
                    } else {
                        parent.log("Skipping nested subcircuit definition at %s:%d: %s".format(
                            currentToken.sourceFile, currentToken.line, lexer.getCurrentLine()));
                        // Still need to handle nesting correctly
                        parseNestedSubcircuit();
                    }
                } else if (currentToken.value == ".ends") {
                    // This should only happen if we're parsing a subcircuit
                    if (!atTopLevel) {
                        // End of subcircuit
                        advance(); // Consume .ends
                        return;
                    } else {
                        // Unexpected .ends at top level
                        parent.log("Unexpected .ends at top level at %s:%d: %s".format(
                            currentToken.sourceFile, currentToken.line, lexer.getCurrentLine()));
                        skipToNextLine();
                    }
                } else {
                    // Other dot commands
                    skipToNextLine();
                }
            } else {
                // Non-command lines
                skipToNextLine();
            }
        }
    }
    
    private void advance() {
        currentToken = lexer.nextToken();
    }
    
    private void skipToNextLine() {
        // Skip tokens until we reach a newline or EOF
        while (currentToken.type != TokenType.NEWLINE && 
               currentToken.type != TokenType.EOF) {
            advance();
        }
        
        // Skip the newline if present
        if (currentToken.type == TokenType.NEWLINE) {
            advance();
        }
    }
    
    private string expectIdentifier() {
        if (currentToken.type != TokenType.IDENTIFIER) {
            parent.log("Expected identifier but found %s at %s:%d".format(
                currentToken.value, currentToken.sourceFile, currentToken.line));
            return "";
        }
        
        string identifier = currentToken.value;
        advance();
        return identifier;
    }
    
    private void expectToken(TokenType type) {
        if (currentToken.type != type) {
            parent.log("Expected %s but found %s at %s:%d".format(
                type, currentToken.type, currentToken.sourceFile, currentToken.line));
            return;
        }
        
        advance();
    }
    
    private string expectValue() {
        if (currentToken.type != TokenType.VALUE && 
            currentToken.type != TokenType.IDENTIFIER) {
            parent.log("Expected value but found %s at %s:%d".format(
                currentToken.value, currentToken.sourceFile, currentToken.line));
            return "";
        }
        
        string value = currentToken.value;
        advance();
        return value;
    }
    
    private void parseModel() {
        size_t startLine = currentToken.line;
        string sourceFile = currentToken.sourceFile;
        
        // Consume .model token
        advance();
        
        // Parse model name
        string modelName = expectIdentifier();
        if (modelName.length == 0) {
            skipToNextLine();
            return;
        }
        
        // Parse model type
        string modelType = expectIdentifier();
        if (modelType.length == 0) {
            skipToNextLine();
            return;
        }
        
        // Check for opening parenthesis
        bool hasParentheses = false;
        if (currentToken.type == TokenType.LPAREN) {
            hasParentheses = true;
            advance();
        }
        
        // Collect all parameter text for expression checking
        string paramString = "";
        Token[] paramTokens = [];
        
        // Store current position to rewind if needed
        Token savedToken = currentToken;
        
        // Collect parameter string for expression checking
        while (currentToken.type != TokenType.NEWLINE && 
               currentToken.type != TokenType.EOF &&
               (!hasParentheses || currentToken.type != TokenType.RPAREN)) {
            paramString ~= currentToken.value ~ " ";
            paramTokens ~= currentToken;
            advance();
        }
        
        // Check entire parameter string for expressions
        if (parent.containsExpressions(paramString)) {
            parent.log("Skipping model '%s': contains expressions or functions in parameters".format(modelName));
            
            // Skip to end of line or closing parenthesis
            if (hasParentheses && currentToken.type == TokenType.RPAREN) {
                advance(); // Consume closing parenthesis
            }
            
            skipToNextLine();
            return;
        }
        
        // Reset to saved position
        currentToken = savedToken;
        
        // Parse parameters
        ParameterValue[string] parameters;
        
        while (currentToken.type != TokenType.NEWLINE && 
               currentToken.type != TokenType.EOF &&
               (!hasParentheses || currentToken.type != TokenType.RPAREN)) {
            
            // Parse parameter name
            string paramName = expectIdentifier();
            if (paramName.length == 0) {
                // Skip to next parameter
                while (currentToken.type != TokenType.NEWLINE && 
                       currentToken.type != TokenType.EOF &&
                       currentToken.type != TokenType.IDENTIFIER &&
                       (!hasParentheses || currentToken.type != TokenType.RPAREN)) {
                    advance();
                }
                continue;
            }
            
            // Clean up parameter name - remove any leftover parentheses
            paramName = paramName.stripLeft("(").stripRight(")");
            
            // Check for equals sign
            if (currentToken.type != TokenType.EQUALS) {
                parent.log("Expected '=' after parameter name '%s' at %s:%d".format(
                    paramName, currentToken.sourceFile, currentToken.line));
                
                // Skip to next parameter
                while (currentToken.type != TokenType.NEWLINE && 
                       currentToken.type != TokenType.EOF &&
                       currentToken.type != TokenType.IDENTIFIER &&
                       (!hasParentheses || currentToken.type != TokenType.RPAREN)) {
                    advance();
                }
                continue;
            }
            
            // Consume equals sign
            advance();
            
            // Parse parameter value
            string paramValue = expectValue();
            if (paramValue.length == 0) {
                // Skip to next parameter
                while (currentToken.type != TokenType.NEWLINE && 
                       currentToken.type != TokenType.EOF &&
                       currentToken.type != TokenType.IDENTIFIER &&
                       (!hasParentheses || currentToken.type != TokenType.RPAREN)) {
                    advance();
                }
                continue;
            }
            
            // Process parameter value
            parameters[paramName] = parent.processParameterValue(paramName, paramValue);
        }
        
        // Consume closing parenthesis if needed
        if (hasParentheses && currentToken.type == TokenType.RPAREN) {
            advance();
        }
        
        // Insert model into database
        auto modelData = ModelData(
            modelName,
            modelType,
            sourceFile,
            startLine,
            parameters
        );
        
        queries.insertModel(modelData);
        
        // Skip to next line
        skipToNextLine();
    }
    
    private void parseSubcircuit() {
        size_t startLine = currentToken.line;
        string sourceFile = currentToken.sourceFile;
        
        // Store the initial .subckt line
        string content = lexer.getCurrentLine() ~ "\n";
        
        // Consume .subckt token
        advance();
        
        // Parse subcircuit name
        string subcktName = expectIdentifier();
        if (subcktName.length == 0) {
            skipToNextLine();
            return;
        }
        
        // Skip the rest of the subcircuit header line
        skipToNextLine();
        
        // Parse subcircuit body
        bool wasAtTopLevel = atTopLevel;
        atTopLevel = false; // We're now inside a subcircuit
        
        // Parse until .ends
        while (currentToken.type != TokenType.EOF) {
            if (currentToken.type == TokenType.DOT_COMMAND && 
                currentToken.value == ".ends") {
                // End of subcircuit
                content ~= lexer.getCurrentLine() ~ "\n";
                advance(); // Consume .ends
                break;
            }
            
            // Capture the current line
            content ~= lexer.getCurrentLine() ~ "\n";
            
            // Handle nested elements
            if (currentToken.type == TokenType.DOT_COMMAND) {
                if (currentToken.value == ".model") {
                    // Skip model inside subcircuit
                    parent.log("Skipping model definition inside subcircuit at %s:%d: %s".format(
                        currentToken.sourceFile, currentToken.line, lexer.getCurrentLine()));
                    skipToNextLine();
                } else if (currentToken.value == ".subckt") {
                    // Handle nested subcircuit
                    parent.log("Skipping nested subcircuit definition at %s:%d: %s".format(
                        currentToken.sourceFile, currentToken.line, lexer.getCurrentLine()));
                    parseNestedSubcircuit();
                } else {
                    // Other dot commands
                    skipToNextLine();
                }
            } else {
                // Regular subcircuit content
                skipToNextLine();
            }
        }
        
        // Restore top level state
        atTopLevel = wasAtTopLevel;
        
        // Check if we reached EOF without finding .ends
        if (currentToken.type == TokenType.EOF) {
            parent.log("Unclosed subcircuit definition starting at %s:%d".format(
                sourceFile, startLine));
            return;
        }
        
        // Insert subcircuit into database
        auto subcktData = SubcircuitData(
            subcktName,
            content,
            sourceFile,
            startLine
        );
        
        queries.insertSubcircuit(subcktData);
    }
    
    private void parseNestedSubcircuit() {
        // We're already inside a subcircuit, so we just need to skip this nested one
        // but maintain proper nesting tracking
        
        // Consume .subckt token
        advance();
        
        // Skip the rest of the subcircuit header line
        skipToNextLine();
        
        // Track nesting level
        int nestingLevel = 1;
        
        // Parse until matching .ends
        while (currentToken.type != TokenType.EOF && nestingLevel > 0) {
            if (currentToken.type == TokenType.DOT_COMMAND) {
                if (currentToken.value == ".subckt") {
                    // Nested subcircuit
                    nestingLevel++;
                } else if (currentToken.value == ".ends") {
                    // End of subcircuit
                    nestingLevel--;
                }
            }
            
            // Skip to next line
            skipToNextLine();
        }
    }
}

version(unittest) {
    import std.file : tempDir;
    import std.path : buildPath;
    import database.schema : createTestDatabase;

    unittest {
        // Test case sensitivity and SI prefixes
        auto db = createTestDatabase();
        auto queries = new DatabaseQueries(db);
        auto parser = new NetlistParser();

        // Test SI prefix handling
        auto testSiPrefixes = NetlistLine(
            ".model test_prefix nmos vth=1.0 cap=1meg res=1m ind=1u freq=1g",
            0,
            "test.sp"
        );
        parser.parseFile("test.sp", queries);

        auto prefix_results = queries.queryModels(ModelFilter("nmos", "test_%", null, 1));
        assert("test_prefix" in prefix_results,
            "Missing 'test_prefix' model. Found models: %s".format(prefix_results.keys));
        
        // First verify model was inserted with all parameters
        auto debug_results = queries.queryModels(ModelFilter("nmos", "test_prefix", null, 1));
        assert("test_prefix" in debug_results, 
            "Model 'test_prefix' was not found in database after insertion. " ~
            "Available models: %s".format(debug_results.keys));
        
        auto debug_model = debug_results["test_prefix"];
        assert(debug_model.parameters.length == 5,
            ("Expected 5 parameters in model 'test_prefix' but found %d. " ~
            "Parameters present: %s").format(
                debug_model.parameters.length, 
                debug_model.parameters.keys));
        assert("vth" in debug_model.parameters, 
            "Parameter 'vth' is missing from model 'test_prefix'. " ~
            "Expected parameters: vth, cap, res, ind, freq. " ~
            "Found parameters: %s".format(debug_model.parameters.keys));
            
        assert("cap" in debug_model.parameters, 
            "Parameter 'cap' is missing from model 'test_prefix'. " ~
            "Expected parameters: vth, cap, res, ind, freq. " ~
            "Found parameters: %s".format(debug_model.parameters.keys));
            
        assert("res" in debug_model.parameters, 
            "Parameter 'res' is missing from model 'test_prefix'. " ~
            "Expected parameters: vth, cap, res, ind, freq. " ~
            "Found parameters: %s".format(debug_model.parameters.keys));
            
        assert("ind" in debug_model.parameters, 
            "Parameter 'ind' is missing from model 'test_prefix'. " ~
            "Expected parameters: vth, cap, res, ind, freq. " ~
            "Found parameters: %s".format(debug_model.parameters.keys));
            
        assert("freq" in debug_model.parameters,
            "Parameter 'freq' is missing from model 'test_prefix'. " ~
            "Expected parameters: vth, cap, res, ind, freq. " ~
            "Found parameters: %s".format(debug_model.parameters.keys));

        // Now check values in queried model          
        auto test_model = prefix_results["test_prefix"];
        assert(test_model.parameters.length > 0,
            "No parameters found in test_model after query");
        assert("cap" in test_model.parameters,
            "Parameter 'cap' missing from test_model after query. Available params: %s".format(
                test_model.parameters.keys));

        // Original assertions with additional debugging context
        assert(test_model.parameters["cap"] == "1meg",
            "Parameter 'cap' value mismatch in model 'test_prefix'. " ~
            "Expected: '1meg' (with SI prefix 'meg'), " ~
            "Actual: '%s'".format(test_model.parameters["cap"]));
            
        assert(test_model.parameters["res"] == "1m",
            "Parameter 'res' value mismatch in model 'test_prefix'. " ~
            "Expected: '1m' (with SI prefix 'm'), " ~
            "Actual: '%s'".format(test_model.parameters["res"]));
            
        assert(test_model.parameters["ind"] == "1u", 
            "Parameter 'ind' value mismatch in model 'test_prefix'. " ~
            "Expected: '1u' (with SI prefix 'u'), " ~
            "Actual: '%s'".format(test_model.parameters["ind"]));
            
        assert(test_model.parameters["freq"] == "1g",
            "Parameter 'freq' value mismatch in model 'test_prefix'. " ~
            "Expected: '1g' (with SI prefix 'g'), " ~
            "Actual: '%s'".format(test_model.parameters["freq"]));

        // Test mixed-case model definitions

        // Test mixed case model definitions - all should be converted to lowercase
        auto testLineUpper = NetlistLine(
            ".model uppernmos nmos l=0.18u w=1u vth=0.7",
            4,
            "test.sp"
        );
        parser.parseFile("test.sp", queries);

        auto testLineLower = NetlistLine(
            ".model lowernmos nmos l=0.18u w=1u vth=0.7",
            5,
            "test.sp"
        );
        parser.parseFile("test.sp", queries);

        auto testLineMixed = NetlistLine(
            ".model mixednmos nmos l=0.18u w=1u vth=0.7",
            6,
            "test.sp"
        );
        parser.parseFile("test.sp", queries);

        // Test regular model parsing without parentheses
        auto testLine1 = NetlistLine(
            ".model test_nmos1 nmos l=0.18u w=1u vth=0.7 tox=1.4e-8",
            1,
            "test.sp"
        );
        parser.parseFile("test.sp", queries);

        // Test model parsing with parentheses
        auto testLine2 = NetlistLine(
            ".model test_nmos2 nmos (l=0.18u w=1u vth=0.7 tox=1.4e-8)",
            2,
            "test.sp"
        );
        parser.parseFile("test.sp", queries);

        // Test model parsing with leading parentheses on parameter
        auto testLine3 = NetlistLine(
            ".model test_nmos3 nmos ((l)=0.18u (w)=1u vth=0.7 tox=1.4e-8)",
            3,
            "test.sp"
        );
        parser.parseFile("test.sp", queries);

        // Test model with expressions - should be skipped
        auto testExprLine = NetlistLine(
            ".model expr_model nmos l='0.18u + 0.02u' w=1u vth=0.7",
            7,
            "test.sp"
        );
        parser.parseFile("test.sp", queries);

        // Test model with function call - should be skipped
        auto testFuncLine = NetlistLine(
            ".model func_model nmos l=max(0.18u,0.2u) w=1u vth=0.7",
            8,
            "test.sp"
        );
        parser.parseFile("test.sp", queries);

        // Query and verify case-insensitive model access
        auto filter = ModelFilter("nmos", null, null, 10);
        auto results = queries.queryModels(filter);
        
        // Check if all models were found regardless of case
        assert(results.length == 6,
            "Expected 6 models (3 case test + 3 parentheses test, 2 expression models skipped), but found %d models: %s".format(
                results.length, results.keys));
        assert("uppernmos" in results,
            "Missing 'uppernmos' model. Found models: %s".format(results.keys));
        assert("lowernmos" in results,
            "Missing 'lowernmos' model. Found models: %s".format(results.keys));
        assert("mixednmos" in results,
            "Missing 'mixednmos' model. Found models: %s".format(results.keys));
        assert("test_nmos1" in results,
            "Missing 'test_nmos1' model. Found models: %s".format(results.keys));
        assert("test_nmos2" in results,
            "Missing 'test_nmos2' model. Found models: %s".format(results.keys));
        assert("test_nmos3" in results,
            "Missing 'test_nmos3' model. Found models: %s".format(results.keys));

        // Verify expression models were skipped
        assert("expr_model" !in results,
            "Found expr_model which should have been skipped: %s".format(results.keys));
        assert("func_model" !in results,
            "Found func_model which should have been skipped: %s".format(results.keys));

        // Check parameter case insensitivity
        foreach (modelName, model; results) {
            assert("l" in model.parameters,
                "Parameter 'l' missing in model %s. Found parameters: %s".format(
                    modelName, model.parameters.keys));
            assert("w" in model.parameters,
                "Parameter 'w' missing in model %s. Found parameters: %s".format(
                    modelName, model.parameters.keys));
            assert("vth" in model.parameters,
                "Parameter 'vth' missing in model %s. Found parameters: %s".format(
                    modelName, model.parameters.keys));
        }

        // Verify parameter values are consistent
        auto upperL = results["uppernmos"].parameters["l"];
        auto lowerL = results["lowernmos"].parameters["l"];
        auto mixedL = results["mixednmos"].parameters["l"];
        
        assert(upperL == lowerL,
            "Parameter 'l' value mismatch between uppernmos (%s) and lowernmos (%s)".format(
                upperL, lowerL));
        assert(lowerL == mixedL,
            "Parameter 'l' value mismatch between lowernmos (%s) and mixednmos (%s)".format(
                lowerL, mixedL));

        // Test case-insensitive subcircuit handling
        auto subcktLines = [
            NetlistLine(".subckt upper_inv in out vdd vss", 1, "test.sp"),
            NetlistLine("m1 out in vss vss nmos", 2, "test.sp"),
            NetlistLine(".ends", 3, "test.sp"),
            NetlistLine(".subckt lower_inv in out vdd vss", 4, "test.sp"),
            NetlistLine("m1 out in vss vss nmos", 5, "test.sp"),
            NetlistLine(".ends", 6, "test.sp"),
            NetlistLine(".subckt mixed_inv in out vdd vss", 7, "test.sp"),
            NetlistLine("m1 out in vss vss nmos", 8, "test.sp"),
            NetlistLine(".ends", 9, "test.sp")
        ];

        // Create a test file for subcircuit testing
        auto testFile = File("test_subckt.sp", "w");
        foreach (line; subcktLines) {
            testFile.writeln(line.content);
        }
        testFile.close();

        parser.parseFile("test_subckt.sp", queries);

        // Verify parentheses handling
        string nmos1L = results["test_nmos1"].parameters["l"];
        string nmos2L = results["test_nmos2"].parameters["l"];
        string nmos3L = results["test_nmos3"].parameters["l"];

        assert(nmos1L == nmos2L,
            "Parameter 'l' value mismatch between test_nmos1 (%s) and test_nmos2 (%s)".format(
                nmos1L, nmos2L));
        assert(nmos2L == nmos3L,
            "Parameter 'l' value mismatch between test_nmos2 (%s) and test_nmos3 (%s)".format(
                nmos2L, nmos3L));

        // Verify subcircuit case-insensitive parsing
        // Query all subcircuits
        auto subcktResults = queries.querySubcircuits(SubcircuitFilter("", 10));
        assert("upper_inv" in subcktResults,
            "Missing 'upper_inv' subcircuit. Found subcircuits: %s".format(subcktResults.keys));
        assert("lower_inv" in subcktResults,
            "Missing 'lower_inv' subcircuit. Found subcircuits: %s".format(subcktResults.keys));
        assert("mixed_inv" in subcktResults,
            "Missing 'mixed_inv' subcircuit. Found subcircuits: %s".format(subcktResults.keys));
        
        // Check that nested subcircuit detection is case-insensitive
        // Create and test nested subcircuit with mixed case
        auto nestedSubcktLines = [
            NetlistLine(".subckt outer", 1, "test_nested.sp"),
            NetlistLine(".subckt inner", 2, "test_nested.sp"),
            NetlistLine("m1 out in vss vss nmos", 3, "test_nested.sp"),
            NetlistLine(".ends", 4, "test_nested.sp"),
            NetlistLine(".ends", 5, "test_nested.sp")
        ];
        
        // Create a test file for nested subcircuit testing
        testFile = File("test_nested.sp", "w");
        foreach (line; nestedSubcktLines) {
            testFile.writeln(line.content);
        }
        testFile.close();
        
        parser.parseFile("test_nested.sp", queries);
        
        // Query again to include nested subcircuit
        auto nestedResults = queries.querySubcircuits(SubcircuitFilter("", 10));
        assert("outer" in nestedResults,
            "Missing nested 'outer' subcircuit. Found subcircuits: %s".format(nestedResults.keys));
        
        // Verify total number of subcircuits
        assert(nestedResults.length == 4,
            "Expected 4 subcircuits (upper_inv, lower_inv, mixed_inv, outer), but found %d: %s".format(
                nestedResults.length, nestedResults.keys));

        // Test model inside subcircuit - should be skipped
        auto modelInSubcktLines = [
            NetlistLine(".subckt with_model", 1, "test_model_in_subckt.sp"),
            NetlistLine(".model inner_model nmos l=0.18u w=1u", 2, "test_model_in_subckt.sp"),
            NetlistLine("m1 out in vss vss inner_model", 3, "test_model_in_subckt.sp"),
            NetlistLine(".ends", 4, "test_model_in_subckt.sp")
        ];
        
        // Create a test file for model in subcircuit testing
        testFile = File("test_model_in_subckt.sp", "w");
        foreach (line; modelInSubcktLines) {
            testFile.writeln(line.content);
        }
        testFile.close();
        
        parser.parseFile("test_model_in_subckt.sp", queries);
        
        // Verify inner model was skipped
        auto innerModelResults = queries.queryModels(ModelFilter("nmos", "inner_model", null, 1));
        assert(innerModelResults.length == 0,
            "Found model 'inner_model' which should have been skipped inside subcircuit");

        // Test subcircuit inside subcircuit - only outer should be parsed
        auto nestedSubcktWithModelLines = [
            NetlistLine(".subckt outer_with_inner", 1, "test_nested_with_model.sp"),
            NetlistLine(".subckt inner_sub", 2, "test_nested_with_model.sp"),
            NetlistLine(".model inner_model2 nmos l=0.18u w=1u", 3, "test_nested_with_model.sp"),
            NetlistLine("m1 out in vss vss inner_model2", 4, "test_nested_with_model.sp"),
            NetlistLine(".ends", 5, "test_nested_with_model.sp"),
            NetlistLine("xinv inner_sub out in vss vss", 6, "test_nested_with_model.sp"),
            NetlistLine(".ends", 7, "test_nested_with_model.sp")
        ];
        
        // Create a test file for nested subcircuit with model testing
        testFile = File("test_nested_with_model.sp", "w");
        foreach (line; nestedSubcktWithModelLines) {
            testFile.writeln(line.content);
        }
        testFile.close();
        
        parser.parseFile("test_nested_with_model.sp", queries);
        
        // Query for subcircuits and models
        auto finalSubcktResults = queries.querySubcircuits(SubcircuitFilter("", 10));
        auto finalModelResults = queries.queryModels(ModelFilter(null, null, null, 10));

        // Verify only outer subcircuit was parsed
        assert("outer_with_inner" in finalSubcktResults,
            "Missing outer subcircuit 'outer_with_inner'");
        assert("inner_sub" !in finalSubcktResults,
            "Found inner subcircuit 'inner_sub' which should have been skipped");
        assert("inner_model2" !in finalModelResults,
            "Found model 'inner_model2' which should have been skipped");
    }
}
