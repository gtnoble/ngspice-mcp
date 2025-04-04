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
    db.execute("PRAGMA journal_mode = WAL");
    
    // Create tables and indices
    createModelDatabase(db);
    
    return db;
}

version(unittest) {
    import std.file : tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    /// Create a temporary database for testing
    Database createTestDatabase() {
        string dbPath = buildPath(tempDir, randomUUID().toString ~ ".db");
        return initializeDatabase(DatabaseConfig(dbPath));
    }
}
