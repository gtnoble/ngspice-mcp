module database.queries;

import d2sqlite3;
import d2sqlite3.database;
import std.typecons : Nullable;
import std.json;
import std.conv;
import std.array;
import std.string;

/// Parameter value type
enum ParamType {
    NUMERIC,
    STRING
}

/// Parameter value with type information
struct ParameterValue {
    string rawValue;
    ParamType type;
    Nullable!double numericValue;
}

/// Model data for database insertion
struct ModelData {
    string name;
    string type;
    string sourceFile;
    size_t lineNumber;
    ParameterValue[string] parameters;
}

/// Subcircuit data for database insertion
struct SubcircuitData {
    string name;
    string content;
    string sourceFile;
    size_t lineNumber;
}

/// Parameter range filter for queries
struct ParameterRange {
    Nullable!double min;
    Nullable!double max;
}

/// Subcircuit query filter
struct SubcircuitFilter {
    string namePattern;            // Optional pattern to match subcircuit names
    size_t maxResults;            // Maximum number of results to return
}

/// Subcircuit query result
struct SubcircuitResult {
    string content;               // Full subcircuit content
    string sourceFile;           // Source file path
    size_t lineNumber;          // Line number in source
}

/// Model query filter
struct ModelFilter {
    string modelType;               // Required
    string namePattern;            // Optional
    ParameterRange[string] ranges; // Optional parameter range filters
    size_t maxResults;            // Maximum number of results to return
}

/// Model query result format
struct ModelResult {
    string[string] parameters;  // Parameter name -> value mappings
}

class DatabaseQueries {
    private Database db;
    private Statement modelInsertStmt;
    private Statement paramInsertStmt;
    private Statement subcircuitInsertStmt;
    private Statement modelQueryStmt;
    private Statement subcircuitQueryStmt;

    this(Database db) {
        this.db = db;
        prepareStatements();
    }

    private void prepareStatements() {
        // Prepare model insert statement
        modelInsertStmt = db.prepare(`
            INSERT INTO models (name, type, source_file, line_number)
            VALUES (:name, :type, :source_file, :line_number)
        `);

        // Prepare parameter insert statement
        paramInsertStmt = db.prepare(`
            INSERT INTO parameters (model_id, name, value, parameter_type, numeric_value)
            VALUES (:model_id, :name, :value, :type, :numeric_value)
        `);

        // Prepare subcircuit insert statement  
        subcircuitInsertStmt = db.prepare(`
            INSERT INTO subcircuits (name, content, source_file, line_number)
            VALUES (:name, :content, :source_file, :line_number)
        `);

        // Prepare model query statement
        immutable modelQuery = `
            WITH matching_models AS (
                SELECT m.id, m.name, m.type, m.source_file, m.line_number
                FROM models m
                WHERE m.type = :type COLLATE NOCASE
                AND (:name_pattern IS NULL OR m.name LIKE :name_pattern COLLATE NOCASE)
            ),
            matching_ranges AS (
                SELECT DISTINCT mm.id
                FROM matching_models mm
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM (
                        SELECT :param_name as name,
                               CAST(:min_val AS REAL) as min_val,
                               CAST(:max_val AS REAL) as max_val
                        WHERE :param_name IS NOT NULL
                    ) range
                    WHERE NOT EXISTS (
                        SELECT 1
                        FROM parameters p
                        WHERE p.model_id = mm.id
                        AND p.name = range.name COLLATE NOCASE
                        AND p.parameter_type = 'NUMERIC'
                        AND (
                            range.min_val IS NULL 
                            OR p.numeric_value >= range.min_val
                        )
                        AND (
                            range.max_val IS NULL 
                            OR p.numeric_value <= range.max_val
                        )
                    )
                )
            )
            SELECT 
                m.name,
                m.type,
                m.source_file,
                m.line_number,
                p.name as param_name,
                p.value as param_value,
                p.parameter_type,
                p.numeric_value
            FROM matching_models m
            INNER JOIN matching_ranges mr ON m.id = mr.id
            LEFT JOIN parameters p ON p.model_id = m.id
            LIMIT :limit`;
        modelQueryStmt = db.prepare(modelQuery);

        // Prepare subcircuit query statement
        subcircuitQueryStmt = db.prepare(`
            WITH matching_subcircuits AS (
                SELECT id, name, content, source_file, line_number
                FROM subcircuits
                WHERE (:name_pattern IS NULL OR name LIKE :name_pattern COLLATE NOCASE)
            )
            SELECT name, content, source_file, line_number
            FROM matching_subcircuits
            LIMIT :limit`);
    }

    /// Insert a new model and its parameters
    void insertModel(const ModelData data) {
        modelInsertStmt.reset();
        modelInsertStmt.bind(":name", data.name);
        modelInsertStmt.bind(":type", data.type);
        modelInsertStmt.bind(":source_file", data.sourceFile);
        modelInsertStmt.bind(":line_number", data.lineNumber);
        modelInsertStmt.execute();
        
        auto modelId = db.lastInsertRowid();

        foreach (name, value; data.parameters) {
            paramInsertStmt.reset();
            paramInsertStmt.bind(":model_id", modelId);
            paramInsertStmt.bind(":name", name);
            paramInsertStmt.bind(":value", value.rawValue);
            paramInsertStmt.bind(":type", value.type.to!string);
            
            if (value.type == ParamType.NUMERIC && !value.numericValue.isNull) {
                paramInsertStmt.bind(":numeric_value", value.numericValue.get());
            } else {
                paramInsertStmt.bind(":numeric_value", null);
            }
            
            paramInsertStmt.execute();
        }
    }

    /// Insert a new subcircuit
    void insertSubcircuit(const SubcircuitData data) {
        subcircuitInsertStmt.reset();
        subcircuitInsertStmt.bind(":name", data.name);
        subcircuitInsertStmt.bind(":content", data.content);
        subcircuitInsertStmt.bind(":source_file", data.sourceFile);
        subcircuitInsertStmt.bind(":line_number", data.lineNumber);
        subcircuitInsertStmt.execute();
    }

    /// Query models based on filter criteria
    ModelResult[string] queryModels(const ModelFilter filter) {
        modelQueryStmt.reset();
        modelQueryStmt.bind(":type", filter.modelType);
        modelQueryStmt.bind(":name_pattern", filter.namePattern.length > 0 ? filter.namePattern : null);
        modelQueryStmt.bind(":limit", filter.maxResults);

        // Bind first parameter range if exists
        if (filter.ranges.length > 0) {
            auto firstRange = filter.ranges.byKeyValue.front;
            modelQueryStmt.bind(":param_name", firstRange.key);
            if (!firstRange.value.min.isNull) {
                modelQueryStmt.bind(":min_val", firstRange.value.min.get());
            } else {
                modelQueryStmt.bind(":min_val", null);
            }
            if (!firstRange.value.max.isNull) {
                modelQueryStmt.bind(":max_val", firstRange.value.max.get());
            } else {
                modelQueryStmt.bind(":max_val", null);
            }
        } else {
            modelQueryStmt.bind(":param_name", null);
            modelQueryStmt.bind(":min_val", null);
            modelQueryStmt.bind(":max_val", null);
        }

        ModelResult[string] results;
        string currentName;
        string[string] currentParams;

        foreach (Row row; modelQueryStmt.execute()) {
            string modelName = row["name"].as!string;
            
            if (modelName != currentName) {
                if (currentName.length > 0) {
                    results[currentName] = ModelResult(currentParams);
                }
                currentName = modelName;
                currentParams = null;
            }

            if (row["param_name"].type != SqliteType.NULL) {
                string paramName = row["param_name"].as!string;
                currentParams[paramName] = row["param_value"].as!string;
            }
        }

        // Add the last model
        if (currentName.length > 0) {
            results[currentName] = ModelResult(currentParams);
        }
        
        return results;
    }

    /// Query subcircuits based on filter criteria
    SubcircuitResult[string] querySubcircuits(const SubcircuitFilter filter) {
        subcircuitQueryStmt.reset();
        subcircuitQueryStmt.bind(":name_pattern", filter.namePattern.length > 0 ? filter.namePattern : null);
        subcircuitQueryStmt.bind(":limit", filter.maxResults);

        // Execute query and process results
        SubcircuitResult[string] results;
        foreach (Row row; subcircuitQueryStmt.execute()) {
            string subcktName = row["name"].as!string;
            results[subcktName] = SubcircuitResult(
                row["content"].as!string,
                row["source_file"].as!string,
                row["line_number"].as!size_t
            );
        }

        return results;
    }
}

version(unittest) {
    import std.exception : assertNotThrown;
    import database.schema : createTestDatabase;

    unittest {
        // Create test database
        auto db = createTestDatabase();
        auto queries = new DatabaseQueries(db);

        // Test model insertion with mixed case
        auto modelData = ModelData(
            "test_model",
            "nmos",
            "test.sp",
            1,
            [
                "l": ParameterValue("0.18u", ParamType.NUMERIC, Nullable!double(0.18e-6)),
                "w": ParameterValue("1u", ParamType.NUMERIC, Nullable!double(1e-6)),
                "label": ParameterValue("test", ParamType.STRING, Nullable!double.init)
            ]
        );

        assertNotThrown(queries.insertModel(modelData));

        // Test case-insensitive model type querying
        auto filter = ModelFilter(
            "nmos",     // modelType (lowercase)
            null,       // namePattern
            null,       // ranges
            10         // maxResults
        );

        auto results = queries.queryModels(filter);
        assert(results.length == 1, 
            "Expected 1 model result, but found %d models: %s".format(
                results.length, results.keys));
        assert("test_model" in results, 
            "Expected 'test_model' in results. Found models: %s".format(results.keys));

        auto modelResult = results["test_model"];
        assert(modelResult.parameters.length == 3,
            "Expected 3 parameters for test_model, but found %d: %s".format(
                modelResult.parameters.length, modelResult.parameters.keys));

        // Verify parameter values
        assert("l" in modelResult.parameters, "Missing 'l' parameter");
        assert(modelResult.parameters["l"] == "0.18u", "Unexpected value for parameter 'l'");

        assert("w" in modelResult.parameters, "Missing 'w' parameter");
        assert(modelResult.parameters["w"] == "1u", "Unexpected value for parameter 'w'");

        assert("label" in modelResult.parameters, "Missing 'label' parameter");
        assert(modelResult.parameters["label"] == "test", "Unexpected value for parameter 'label'");

        // Test case-insensitive name pattern matching
        filter.namePattern = "test%";
        results = queries.queryModels(filter);
        assert(results.length == 1,
            "Expected 1 model result for name pattern, but found %d models: %s".format(
                results.length, results.keys));
        // Test case-insensitive parameter name matching
        ParameterRange[string] ranges;
        ranges["l"] = ParameterRange(Nullable!double(0.1e-6), Nullable!double(0.2e-6));
        filter = ModelFilter(
            "nmos",     // modelType
            null,       // namePattern
            ranges,     // ranges (lowercase parameter name)
            10         // maxResults
        );

        results = queries.queryModels(filter);
        assert(results.length == 1,
            "Expected 1 model result for parameter range, but found %d models: %s".format(
                results.length, results.keys));
        modelResult = results["test_model"];
        assert(modelResult.parameters["l"] == "0.18u", 
            "Parameter 'l' value should match when in range");

    }

    // Test subcircuit querying
    unittest {
        auto db = createTestDatabase();
        auto queries = new DatabaseQueries(db);

        // Insert test subcircuit with mixed case
        auto subcktData = SubcircuitData(
            "test_inv",
            ".subckt test_inv in out vdd vss\nm1 out in vss vss nmos\n.ends",
            "test.sp",
            1
        );
        queries.insertSubcircuit(subcktData);

        // Test case-insensitive subcircuit querying
        auto filter = SubcircuitFilter(
            "test%",    // namePattern
            10          // maxResults
        );

        auto results = queries.querySubcircuits(filter);
        assert(results.length == 1);
        assert("test_inv" in results);
        assert(results["test_inv"].sourceFile == "test.sp");
        assert(results["test_inv"].lineNumber == 1);

        // Test full subcircuit content
        auto content = results["test_inv"].content;
        assert(content.indexOf("m1 out in vss vss nmos") != -1);
    }
}
