module database.schema;

import d2sqlite3;

/// Create the database tables and indices for model storage
void createModelDatabase(Database db) {
    // Models table
    db.execute(`
        CREATE TABLE IF NOT EXISTS models (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            type TEXT NOT NULL,
            source_file TEXT NOT NULL,
            line_number INTEGER NOT NULL
        )
    `);

    // Parameters table with type information
    db.execute(`
        CREATE TABLE IF NOT EXISTS parameters (
            id INTEGER PRIMARY KEY,
            model_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            value TEXT NOT NULL,
            parameter_type TEXT NOT NULL,
            numeric_value REAL,
            FOREIGN KEY (model_id) REFERENCES models(id)
        )
    `);

    // Subcircuits table
    db.execute(`
        CREATE TABLE IF NOT EXISTS subcircuits (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            content TEXT NOT NULL,
            source_file TEXT NOT NULL,
            line_number INTEGER NOT NULL
        )
    `);

    // Create indices for efficient querying
    db.execute("CREATE INDEX IF NOT EXISTS idx_models_type ON models(type)");
    db.execute("CREATE INDEX IF NOT EXISTS idx_models_name ON models(name)");
    db.execute("CREATE INDEX IF NOT EXISTS idx_parameters_model ON parameters(model_id)");
    db.execute("CREATE INDEX IF NOT EXISTS idx_parameters_name ON parameters(name)");
    db.execute("CREATE INDEX IF NOT EXISTS idx_parameters_numeric ON parameters(name, numeric_value) WHERE parameter_type = 'NUMERIC'");
    db.execute("CREATE INDEX IF NOT EXISTS idx_subcircuits_name ON subcircuits(name)");
}

/// Database connection configuration
struct DatabaseConfig {
    string dbPath;
    size_t maxResults = 20;
}

/// Initialize a new database connection with the given configuration
Database initializeDatabase(DatabaseConfig config) {
    auto db = Database(config.dbPath);
    
    // Enable foreign keys
    db.execute("PRAGMA foreign_keys = ON");
    
    // Create tables and indices
    createModelDatabase(db);
    
    return db;
}

/// Database connection pool for thread-safe access
class DatabasePool {
    private {
        DatabaseConfig config;
        Database db;
    }

    this(DatabaseConfig config) {
        this.config = config;
        this.db = initializeDatabase(config);
    }

    /// Get the database connection
    Database getConnection() {
        return db;
    }

    /// Get the maximum number of results to return
    size_t getMaxResults() {
        return config.maxResults;
    }
}

version(unittest) {
    import std.file : tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    /// Create a temporary database for testing
    DatabasePool createTestDatabase() {
        string dbPath = buildPath(tempDir, randomUUID().toString ~ ".db");
        auto config = DatabaseConfig(dbPath);
        return new DatabasePool(config);
    }
}
