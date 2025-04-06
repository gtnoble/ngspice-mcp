# ngspice-mcp

A Model Context Protocol (MCP) server that provides access to ngspice circuit simulation functionality through a standardized protocol interface. This server enables AI language models to interact with ngspice in a controlled and structured way.

## Features

- Integration with ngspice's shared library interface
- Standardized MCP protocol implementation
- Synchronous operation with structured data access
- Comprehensive output capture and redirection
- Vector data handling with multiple representation formats
- Support for both server and library usage modes
- Built-in test suite

## Requirements

- D compiler (DMD/LDC)
- ngspice shared library
- MCP server library (d-mcp-server)
- D build system (dub)

## Installation

1. Ensure system requirements are installed
2. Clone the repository
3. Build using dub:

```bash
dub build --config=server
```

## Usage

The server can be started with:

```bash
./ngspice-mcp [options]
```

### Command Line Options

- `--working-dir`, `-d`: Set the working directory for circuit files (default: current directory)

### Available Tools

#### Circuit Loading
- `loadCircuit`: Load circuit netlists directly
- `loadNetlistFromFile`: Load netlists from files

Example netlist:
```spice
RC Circuit
R1 in out 1k
C1 out 0 1u
.end
```

#### Simulation
- `runSimulation`: Execute simulation commands

Common commands:
- `op`: DC operating point
- `dc source start stop step`
- `ac dec points fstart fend`
- `tran step tstop`

#### Data Access
- `getPlotNames`: List available simulation plots
- `getVectorNames`: List vectors in a specific plot
- `getVectorData`: Retrieve vector data with options for:
  - Magnitude-phase representation
  - Rectangular (real-imaginary) representation
  - Both representations
  - Optional interval selection

### Resources

- `stdout://`: Standard output stream from ngspice
- `stderr://`: Error output stream from ngspice
- `usage://`: Comprehensive usage guide

## Development

### Project Structure

```
ngspice-mcp/
├── source/
│   ├── app.d           # Main application
│   ├── bindings/       # ngspice C API bindings
│   ├── database/       # SQLite database handling
│   ├── parser/         # Netlist parsing
│   └── server/         # MCP server implementation
├── resources/          # Resource files
└── bin/               # Build outputs
```

### Build Configurations

1. **Server Mode**
```bash
dub build --config=server
```

2. **Library Mode**
```bash
dub build --config=library
```

3. **Unit Tests**
```bash
dub test --config=unittest
```

### Testing

Run the test suite:
```bash
dub test
```

Tests cover:
- ngspice bindings
- Server functionality
- Tool validation
- Resource handling
- Error cases

## Technical Details

### Architecture

The server implements several key components:

1. **NgspiceServer**: Core server implementation
   - Tool registration and handling
   - Resource management
   - Output stream capture
   - Vector data processing

2. **Output System**
   - Stdout/stderr capture
   - Stream buffering
   - Resource notification

3. **Vector Processing**
   - Complex number handling
   - Scientific notation formatting
   - Interval selection
   - Multiple representation formats

### Database System

- Model parameter storage
- Efficient indexing and querying
- Transaction support
- Concurrent access handling

## License

MIT License - see [dub.json](dub.json) for details.

Copyright © 2024, Garret Noble

## Contributing

Contributions are welcome! Please ensure:

1. Code follows project style and standards
2. Tests are included for new functionality
3. Documentation is updated as needed
4. Commit messages are clear and descriptive
