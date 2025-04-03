module database.queries;

import d2sqlite3;
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

    this(Database db) {
        this.db = db;
    }

    /// Insert a new model and its parameters
    void insertModel(const ModelData data) {
        auto stmt = db.prepare(`
            INSERT INTO models (name, type, source_file, line_number)
            VALUES (:name, :type, :source_file, :line_number)
        `);
        stmt.bind(":name", data.name);
        stmt.bind(":type", data.type);
        stmt.bind(":source_file", data.sourceFile);
        stmt.bind(":line_number", data.lineNumber);
        stmt.execute();
        
        auto modelId = db.lastInsertRowid();

        // Insert parameters
        auto paramStmt = db.prepare(`
            INSERT INTO parameters (model_id, name, value, parameter_type, numeric_value)
            VALUES (:model_id, :name, :value, :type, :numeric_value)
        `);

        foreach (name, value; data.parameters) {
            paramStmt.reset();
            paramStmt.bind(":model_id", modelId);
            paramStmt.bind(":name", name);
            paramStmt.bind(":value", value.rawValue);
            paramStmt.bind(":type", value.type.to!string);
            
            if (value.type == ParamType.NUMERIC && !value.numericValue.isNull) {
                paramStmt.bind(":numeric_value", value.numericValue.get());
            } else {
                paramStmt.bind(":numeric_value", null);
            }
            
            paramStmt.execute();
        }
    }

    /// Insert a new subcircuit
    void insertSubcircuit(const SubcircuitData data) {
        auto stmt = db.prepare(`
            INSERT INTO subcircuits (name, content, source_file, line_number)
            VALUES (:name, :content, :source_file, :line_number)
        `);
        stmt.bind(":name", data.name);
        stmt.bind(":content", data.content);
        stmt.bind(":source_file", data.sourceFile);
        stmt.bind(":line_number", data.lineNumber);
        stmt.execute();
    }

    /// Query models based on filter criteria
    ModelResult[string] queryModels(const ModelFilter filter) {
        // Build query parts
        string baseQuery = `
            SELECT DISTINCT m.id, m.name,
                   GROUP_CONCAT(p.name || ':' || p.value, ';') as params
            FROM models m
            LEFT JOIN parameters p ON p.model_id = m.id
            WHERE m.type = :type
        `;

        string[] conditions;
        if (filter.namePattern && filter.namePattern.length > 0) {
            conditions ~= "m.name LIKE :name_pattern";
        }

        // Add parameter range conditions
        size_t rangeIndex = 0;
        foreach (paramName, range; filter.ranges) {
            string paramCond = "EXISTS (SELECT 1 FROM parameters p" ~ rangeIndex.to!string ~
                             " WHERE p" ~ rangeIndex.to!string ~ ".model_id = m.id" ~
                             " AND p" ~ rangeIndex.to!string ~ ".name = :param_name" ~ rangeIndex.to!string;
            
            if (!range.min.isNull) {
                paramCond ~= " AND p" ~ rangeIndex.to!string ~ ".numeric_value >= :min" ~ rangeIndex.to!string;
            }
            if (!range.max.isNull) {
                paramCond ~= " AND p" ~ rangeIndex.to!string ~ ".numeric_value <= :max" ~ rangeIndex.to!string;
            }
            paramCond ~= ")";
            conditions ~= paramCond;
            rangeIndex++;
        }

        // Combine conditions
        if (conditions.length > 0) {
            baseQuery ~= " AND " ~ conditions.join(" AND ");
        }

        // Add group by and limit
        baseQuery ~= " GROUP BY m.id LIMIT :limit";

        // Prepare and bind query
        auto stmt = db.prepare(baseQuery);
        stmt.bind(":type", filter.modelType);
        stmt.bind(":limit", filter.maxResults);

        if (filter.namePattern && filter.namePattern.length > 0) {
            stmt.bind(":name_pattern", filter.namePattern);
        }

        // Bind parameter range values
        rangeIndex = 0;
        foreach (paramName, range; filter.ranges) {
            stmt.bind(":param_name" ~ rangeIndex.to!string, paramName);
            if (!range.min.isNull) {
                stmt.bind(":min" ~ rangeIndex.to!string, range.min.get());
            }
            if (!range.max.isNull) {
                stmt.bind(":max" ~ rangeIndex.to!string, range.max.get());
            }
            rangeIndex++;
        }

        // Execute query and process results
        ModelResult[string] results;
        foreach (Row row; stmt.execute()) {
            string modelName = row["name"].as!string;
            string paramsStr = row["params"].as!string;
            
            // Parse parameters string
            ModelResult result;
            foreach (paramPair; paramsStr.split(";")) {
                auto parts = paramPair.split(":");
                if (parts.length == 2) {
                    result.parameters[parts[0]] = parts[1];
                }
            }
            
            results[modelName] = result;
        }

        return results;
    }
}

version(unittest) {
    import std.exception : assertNotThrown;
    import database.schema : createTestDatabase;

    unittest {
        auto dbPool = createTestDatabase();
        auto db = dbPool.getConnection();
        auto queries = new DatabaseQueries(db);

        // Test model insertion
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

        // Test model querying
        auto filter = ModelFilter(
            "nmos",     // modelType
            null,       // namePattern
            null,       // ranges
            10         // maxResults
        );

        auto results = queries.queryModels(filter);
        assert(results.length == 1);
        assert("test_model" in results);
        assert(results["test_model"].parameters.length == 3);
    }
}
