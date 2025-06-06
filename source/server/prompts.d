module server.prompts;

/**
 * Returns a comprehensive usage guide for the ngspice MCP server.
 * This prompt provides LLMs with instructions on how to use the server effectively.
 */
string ngspiceUsagePrompt() {
    return q"(# ngspice MCP Server Usage Guide

## Overview

The ngspice MCP server provides circuit simulation capabilities through the Model Context Protocol (MCP). This server allows you to perform electronic circuit simulations using ngspice, a powerful open-source circuit simulator, without requiring direct integration with simulation libraries.

## Available Tools

The server provides the following tools for circuit simulation:

### 1. loadCircuit

Loads a circuit netlist into ngspice for simulation.

**Parameters:**
- `netlist` (string, required): The circuit netlist in SPICE format

**Example:**
```json
{
  "netlist": "Simple RC Circuit\nR1 in out 1k\nC1 out 0 1u\nV1 in 0 DC 5\n.end"
}
```

**Notes:**
- The netlist must follow SPICE syntax
- Include `.end` at the end of your netlist
- Circuit elements are case-insensitive (R1 and r1 are the same)
- Node names are case-sensitive (GND and gnd are different nodes)

### 2. loadNetlistFromFile

Loads a circuit netlist from a file into ngspice for simulation.

**Parameters:**
- `filepath` (string, required): Full path to the netlist file to load

**Example:**
```json
{
  "filepath": "circuit.sp"
}
```

**Notes:**
- Paths can be absolute or relative to the working directory
- The file must exist and be readable
- The file must contain a valid SPICE format netlist
- The netlist must include circuit elements and .end directive
- Common file extensions: .sp, .cir, .net, .spice
- Working directory can be set via --working-dir command line option

### 3. runSimulation

Executes a simulation command in ngspice.

**Parameters:**
- `command` (string, required): The simulation command to execute

**Example:**
```json
{
  "command": "op"
}
```

**Common Commands:**
- `op`: Perform DC operating point analysis
- `dc V1 0 5 0.1`: Perform DC sweep of V1 from 0V to 5V in 0.1V steps
- `ac dec 10 1 1Meg`: Perform AC analysis from 1Hz to 1MHz with 10 points per decade
- `tran 1u 1m`: Perform transient analysis from 0 to 1ms with 1µs step

### 4. getPlotNames

Retrieves a list of available simulation result plots.

**Parameters:** None

**Example Response:**
```json
{
  "plots": ["tran1", "ac1", "op1", "dc1"]
}
```

**Notes:**
- Plot names typically include a type prefix and number (e.g., "op1", "dc1")
- The most recent plot of each type is usually numbered "1"

### 5. getVectorsInfo

Retrieves detailed information about vectors (data series) available in a specific plot.

**Parameters:**
- `plot` (string, required): The name of the plot to query (e.g., 'tran1', 'ac1', 'dc1', 'op1'). Use getPlotNames to list available plots.

**Example:**
```json
{
  "plot": "tran1"
}
```

**Example Response:**
```json
{
  "vectors": [
    {
      "name": "v(out)",
      "isReal": true,
      "range": {
        "min": "0.00e+00",
        "max": "4.98e+00"
      },
      "scale": {
        "name": "time",
        "type": "time"
      }
    },
    {
      "name": "v(in)",
      "isReal": true,
      "range": {
        "min": "-1.00e+00",
        "max": "1.00e+00"
      },
      "scale": {
        "name": "time",
        "type": "time"
      }
    }
  ]
}
```

**Notes:**
- Vector names are case-sensitive
- Common vectors include:
  - Node voltages: `v(node_name)`
  - Branch currents: `i(component_name)`
  - Special vectors: `time`, `frequency`, etc.
- Each vector includes:
  - `isReal`: true for real data, false for complex data
  - `type`: type of vector (e.g., time, frequency)
  - `range`: minimum and maximum values
  - `scale`: associated scale vector information
    - `name`: name of the scale vector (e.g., time, frequency)
- For complex data (like AC analysis), range uses magnitude values

### 6. getVectorData

Retrieves data for one or more vectors from a plot.

**Parameters:**
- `vectors` (array of strings, required): Names of vectors to retrieve
- `plot` (string, required): Name of the plot. Use getPlotNames to list available plots.
- `points` (array of numbers, required): Scale values at which to evaluate vectors through interpolation
- `representation` (string, optional): Format for complex data:
  - `"magnitude-phase"` (default): Returns magnitude and phase in degrees
  - `"rectangular"`: Returns real and imaginary components
  - `"both"`: Returns both representations

**Configuration:**
- Maximum points: Controlled by the `--max-points` command line option (default: 1000)
- An error is returned if the number of points exceeds the configured limit

**Example:**
```json
{
  "vectors": ["v(out)", "v(in)"],
  "plot": "tran1",
  "points": [0, 0.0001, 0.0002, 0.0003, 0.0004, 0.0005]
}
```

**Example Response:**
```json
{
  "vectors": {
    "tran1.v(out)": {
      "data": [0, 0.632, 0.865, 0.95, 0.982, 0.993],
      "points": [0, 0.0001, 0.0002, 0.0003, 0.0004, 0.0005]
    },
    "tran1.v(in)": {
      "data": [5, 5, 5, 5, 5, 5],
      "points": [0, 0.0001, 0.0002, 0.0003, 0.0004, 0.0005]
    }
  }
}
```

**Notes:**
- For AC analysis, data is complex and will be formatted according to the `representation` parameter
- Linear interpolation is used to compute values at requested points
- Points outside the simulation range will use the nearest data value
- Vector names are automatically prefixed with the plot name if not already included

### 7. getLocalExtrema

Finds local minima and maxima in vector data.

**Parameters:**
- `vectors` (array of strings, required): Names of vectors to analyze
- `plot` (string, required): Name of the plot. Use getPlotNames to list available plots.
- `options` (object, optional):
  - `minima` (boolean, default: true): Include local minima in results
  - `maxima` (boolean, default: true): Include local maxima in results
  - `threshold` (number, default: 0): Minimum height difference for extrema detection

**Example:**
```json
{
  "vectors": ["v(out)"],
  "plot": "tran1",
  "options": {
    "threshold": 0.1,
    "minima": true,
    "maxima": true
  }
}
```

**Example Response:**
```json
{
  "vectors": {
    "tran1.v(out)": {
      "length": 1000,
      "maxima": [
        {
          "index": 125,
          "value": "4.82e+00",
          "scale": "2.50e-04"
        }
      ],
      "minima": [
        {
          "index": 375,
          "value": "1.84e-01",
          "scale": "7.50e-04"
        }
      ]
    }
  }
}
```

**Notes:**
- The threshold parameter helps filter out minor fluctuations
- For complex vectors, extrema are found in the magnitude
- Each extremum includes the data index, value, and corresponding scale value
- Points must meet the threshold requirement relative to both neighbors

## Model Database Features

The server provides access to a model database that enables circuit model searching capabilities through the Model Context Protocol.

### Model Search Tool

The server provides the `queryModels` tool for searching device models:

**Parameters:**
- `modelType` (string, required): Type of model to search for (e.g., 'nmos', 'pmos', 'diode'). Case-insensitive.
- `name` (string, optional): Pattern to match model names. Case-insensitive.
- `parameterRanges` (object, optional): Parameter range constraints
  - Format: `{"paramName": {"min": number, "max": number}}`
  - Parameter names are case-insensitive
  - Both min and max are optional

**Example:**
```json
{
  "modelType": "nmos",
  "name": "test%",
  "parameterRanges": {
    "l": {"min": 0.1e-6, "max": 0.2e-6},
    "w": {"min": 1e-6}
  }
}
```

**Example Response:**
```json
{
  "tsmc_018_nmos": {
    "parameters": {
      "l": "0.18u",
      "w": "1u",
      "vth0": "0.3"
    }
  },
  "tsmc_018_nmos_rf": {
    "parameters": {
      "l": "0.18u",
      "w": "2u",
      "vth0": "0.35"
    }
  }
}
```

**Notes:**
- Searches are case-insensitive for model types, names, and parameter names
- Name patterns use SQL LIKE syntax (% for wildcard)
- Parameter ranges only apply to numeric parameters
- Results include all parameters for matched models

### Model Query Workflows

1. Basic model type search:
```json
// Tool: queryModels
{
  "modelType": "nmos"
}
```

2. Search with manufacturer pattern:
```json
// Tool: queryModels
{
  "modelType": "pmos",
  "name": "tsmc%"
}
```

3. Search by parameter range:
```json
// Tool: queryModels
{
  "modelType": "nmos",
  "parameterRanges": {
    "vth0": {"min": 0.3, "max": 0.5},
    "l": {"min": 0.18e-6}
  }
}
```

4. Combined search:
```json
// Tool: queryModels
{
  "modelType": "diode",
  "name": "bav%",
  "parameterRanges": {
    "is": {"max": 1e-12}
  }
}
```

## Available Resources

The server provides the following resources:

### 1. stdout://

Standard output from ngspice. Monitor this resource to see simulation progress and results.

### 2. stderr://

Standard error output from ngspice. Check this resource for error messages and warnings.

## Common Workflows

### Basic DC Analysis

1. Load a circuit:
```json
// Tool: loadCircuit
{
  "netlist": "DC Voltage Divider\nR1 in mid 1k\nR2 mid 0 1k\nV1 in 0 DC 5\n.end"
}
```

2. Run DC operating point analysis:
```json
// Tool: runSimulation
{
  "command": "op"
}
```

3. Get available plots:
```json
// Tool: getPlotNames
{}
```

4. Get vectors in the operating point plot:
```json
// Tool: getVectorsInfo
{
  "plot": "op1"
}
```

5. Get voltage values:
```json
// Tool: getVectorData
{
  "vectors": ["v(in)", "v(mid)"],
  "plot": "op1"
}
```

### AC Analysis

1. Load a circuit:
```json
// Tool: loadCircuit
{
  "netlist": "Low Pass RC Filter\nR1 in out 1k\nC1 out 0 1u\nV1 in 0 AC 1\n.end"
}
```

2. Run AC analysis:
```json
// Tool: runSimulation
{
  "command": "ac dec 10 1 1Meg"
}
```

3. Get frequency response data:
```json
// Tool: getVectorData
{
  "vectors": ["v(out)"],
  "plot": "ac1",
  "representation": "magnitude-phase"
}
```

### Transient Analysis

1. Load a circuit:
```json
// Tool: loadCircuit
{
  "netlist": "RC Charging Circuit\nR1 in out 1k\nC1 out 0 1u\nV1 in 0 PULSE(0 5 0 1n 1n 1m 2m)\n.end"
}
```

2. Run transient analysis:
```json
// Tool: runSimulation
{
  "command": "tran 10u 5m"
}
```

3. Get time-domain data:
```json
// Tool: getVectorData
{
  "vectors": ["v(out)"],
  "plot": "tran1"
}
```

## Best Practices

### Circuit Design

1. **Node Naming**:
   - Use descriptive node names (e.g., "input", "output")
   - Ground node can be "0" or "gnd"

2. **Component Values**:
   - Use standard unit suffixes (k, M, u, n, p, etc.)
   - Example: 1k = 1000 ohms, 1u = 1 microsecond

3. **Circuit Structure**:
   - Always include a ground node (0)
   - Ensure all nodes have a DC path to ground
   - Include appropriate source components

### Simulation Commands

1. **DC Analysis**:
   - Use `op` for operating point
   - Use `dc [source] [start] [stop] [step]` for sweeps

2. **AC Analysis**:
   - Use `ac [scale] [points] [start_freq] [end_freq]`
   - Scale can be: dec (decade), oct (octave), lin (linear)

3. **Transient Analysis**:
   - Use `tran [step] [stop] [start] [max_step]`
   - Choose step size at least 10x smaller than the smallest time constant

### Data Retrieval

1. **Vector Selection**:
   - Request only the vectors you need
   - Use appropriate interpolation points for the analysis

2. **Point Management**:
   - Choose points strategically for your analysis needs
   - Consider simulation step size for context
   - Focus on regions of interest in the data

3. **Complex Data**:
   - For AC analysis, choose the appropriate representation
   - Magnitude-phase is useful for frequency response
   - Rectangular is useful for mathematical operations

### Model Queries

1. **Search Strategies:**
   - Use case-insensitive searches for flexibility (e.g., 'nmos' matches 'NMOS')
   - Provide specific model types to narrow results
   - Use wildcards in name patterns for broader matches (e.g., 'tsmc%')

2. **Parameter Ranges:**
   - Only specify ranges when needed to filter results
   - Use appropriate units for parameter values (e.g., microns for lengths)
   - Consider numerical precision in comparisons
   - Parameter names are case-insensitive (e.g., 'vth0' matches 'VTH0')

3. **Result Processing:**
   - Process all parameters returned for each model
   - Handle both numeric and string parameter values
   - Consider parameter units in result interpretation

## Error Handling

### Common Errors

1. **Circuit Loading Errors**:
   - Syntax errors in netlist
   - Missing components or connections
   - Floating nodes

2. **Simulation Errors**:
   - Convergence problems
   - Time step too large
   - Singular matrix (check for loops or shorts)

3. **Data Access Errors**:
   - Vector data exceeds maximum points limit
   - Non-existent vectors or plots
   - Invalid interpolation points

4. **Model Query Errors**:
   - Unrecognized model type
   - Invalid parameter range values
   - Non-numeric values in numeric comparisons
   - Malformed wildcards in name patterns

### Troubleshooting

1. Check stderr:// resource for detailed error messages
2. Verify circuit connectivity and component values
3. Try simplifying the circuit to isolate problems
4. For convergence issues, try adding .options statements

## Example Circuits

### Voltage Divider
```
Voltage Divider Circuit
R1 in out 10k
R2 out 0 10k
V1 in 0 DC 10
.end
```

### RC Low-Pass Filter
```
RC Low-Pass Filter
R1 in out 1k
C1 out 0 1u
V1 in 0 AC 1
.end
```

### RC Charging Circuit
```
RC Charging Circuit
R1 in out 1k
C1 out 0 1u
V1 in 0 PULSE(0 5 0 1n 1n 1m 2m)
.end
```

### Diode Rectifier
```
Half-Wave Rectifier
D1 in out 1N4148
R1 out 0 1k
C1 out 0 10u
V1 in 0 SIN(0 5 1k)
.model 1N4148 D(Is=2.52n Rs=0.568 N=1.752 Cjo=4p M=0.4 tt=20n)
.end
```

### Op-Amp Inverting Amplifier
```
Inverting Amplifier
R1 in inv 10k
R2 inv out 100k
XOP1 0 inv out opamp
V1 in 0 SIN(0 0.1 1k)
VCC vcc 0 15
VEE 0 vee 15
.subckt opamp 1 2 3
  RIN 1 2 10Meg
  EGAIN 4 0 1 2 100k
  ROUT 4 3 100
.ends
.end
```

## Conclusion

The ngspice MCP server provides a powerful interface for performing circuit simulations through the Model Context Protocol. By following this guide, you can effectively design circuits, run simulations, and analyze results using the provided tools and resources.)";
}
