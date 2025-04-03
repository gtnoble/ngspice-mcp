module test.numeric;

import std.math : isClose, isNaN;
import std.conv : to;
import server.ngspice_server : roundToSigFigs;

// Test normal cases
@("roundToSigFigs normal cases")
unittest {
    // Integers
    assert(roundToSigFigs(123.0) == 123.0, "Expected 123.0 to remain unchanged but got " ~ roundToSigFigs(123.0).to!string);
    assert(roundToSigFigs(1234.0) == 1230.0, "Expected 1234.0 to round to 1230.0 (3 sig figs) but got " ~ roundToSigFigs(1234.0).to!string);
    assert(roundToSigFigs(12345.0) == 12300.0, "Expected 12345.0 to round to 12300.0 (3 sig figs) but got " ~ roundToSigFigs(12345.0).to!string);
    
    // Decimals
    assert(roundToSigFigs(1.23) == 1.23, "Expected 1.23 to remain unchanged but got " ~ roundToSigFigs(1.23).to!string);
    assert(roundToSigFigs(12.34) == 12.3, "Expected 12.34 to round to 12.3 (3 sig figs) but got " ~ roundToSigFigs(12.34).to!string);
    assert(roundToSigFigs(0.123) == 0.123, "Expected 0.123 to remain unchanged but got " ~ roundToSigFigs(0.123).to!string);
    assert(roundToSigFigs(0.1234) == 0.123, "Expected 0.1234 to round to 0.123 (3 sig figs) but got " ~ roundToSigFigs(0.1234).to!string);
}

// Test edge cases near power-of-10 boundaries
@("roundToSigFigs power-of-10 boundaries")
unittest {
    assert(roundToSigFigs(9.99) == 9.99, "Expected boundary value 9.99 to remain unchanged but got " ~ roundToSigFigs(9.99).to!string);
    assert(roundToSigFigs(9.999) == 10.0, "Expected 9.999 to round up to 10.0 (3 sig figs) but got " ~ roundToSigFigs(9.999).to!string);
    assert(roundToSigFigs(99.9) == 99.9, "Expected boundary value 99.9 to remain unchanged but got " ~ roundToSigFigs(99.9).to!string);
    assert(roundToSigFigs(99.99) == 100.0, "Expected 99.99 to round up to 100.0 (3 sig figs) but got " ~ roundToSigFigs(99.99).to!string);
    assert(roundToSigFigs(999.9) == 1000.0, "Expected 999.9 to round up to 1000.0 (3 sig figs) but got " ~ roundToSigFigs(999.9).to!string);
}

// Test sign handling
@("roundToSigFigs sign handling")
unittest {
    assert(roundToSigFigs(-123.0) == -123.0, "Expected -123.0 to remain unchanged but got " ~ roundToSigFigs(-123.0).to!string);
    assert(roundToSigFigs(-1234.0) == -1230.0, "Expected -1234.0 to round to -1230.0 (3 sig figs) but got " ~ roundToSigFigs(-1234.0).to!string);
    assert(roundToSigFigs(-0.1234) == -0.123, "Expected -0.1234 to round to -0.123 (3 sig figs) but got " ~ roundToSigFigs(-0.1234).to!string);
    assert(roundToSigFigs(-9.999) == -10.0, "Expected -9.999 to round to -10.0 (3 sig figs) but got " ~ roundToSigFigs(-9.999).to!string);
}

// Test special cases
@("roundToSigFigs special cases")
unittest {
    import std.math : isInfinity;

    // Zero
    assert(roundToSigFigs(0.0) == 0.0, "Expected 0.0 to remain unchanged but got " ~ roundToSigFigs(0.0).to!string);
    
    // Very small numbers
    assert(roundToSigFigs(0.000123456) == 0.000123, "Expected 0.000123456 to round to 0.000123 (3 sig figs) but got " ~ roundToSigFigs(0.000123456).to!string);
    assert(roundToSigFigs(-0.000123456) == -0.000123, "Expected -0.000123456 to round to -0.000123 (3 sig figs) but got " ~ roundToSigFigs(-0.000123456).to!string);
    
    // Very large numbers
    assert(roundToSigFigs(123456789.0) == 123000000.0, "Expected 123456789.0 to round to 123000000.0 (3 sig figs) but got " ~ roundToSigFigs(123456789.0).to!string);
    assert(roundToSigFigs(-123456789.0) == -123000000.0, "Expected -123456789.0 to round to -123000000.0 (3 sig figs) but got " ~ roundToSigFigs(-123456789.0).to!string);
    
    // Special values
    assert(roundToSigFigs(double.infinity).isInfinity, "Expected infinity to remain infinity");
    assert(roundToSigFigs(-double.infinity).isInfinity, "Expected -infinity to remain infinity");
    assert(roundToSigFigs(double.nan).isNaN, "Expected NaN to remain NaN");
}

// Test precision variation
@("roundToSigFigs precision variation")
unittest {
    // Test with different significant figures
    assert(roundToSigFigs(123.456, 1) == 100.0, "With 1 significant figure, expected 123.456 to round to 100.0 but got " ~ roundToSigFigs(123.456, 1).to!string);
    assert(roundToSigFigs(123.456, 2) == 120.0, "With 2 significant figures, expected 123.456 to round to 120.0 but got " ~ roundToSigFigs(123.456, 2).to!string);
    assert(roundToSigFigs(123.456, 4) == 123.5, "With 4 significant figures, expected 123.456 to round to 123.5 but got " ~ roundToSigFigs(123.456, 4).to!string);
    assert(roundToSigFigs(123.456, 5) == 123.46, "With 5 significant figures, expected 123.456 to round to 123.46 but got " ~ roundToSigFigs(123.456, 5).to!string);
    
    // Test invalid sigFigs parameter
    assert(roundToSigFigs(123.456, 0) == 123.456, "With invalid sigFigs=0, expected value to remain unchanged but got " ~ roundToSigFigs(123.456, 0).to!string);
    assert(roundToSigFigs(123.456, -1) == 123.456, "With invalid sigFigs=-1, expected value to remain unchanged but got " ~ roundToSigFigs(123.456, -1).to!string);
}

// Test scientific notation values
@("roundToSigFigs scientific notation")
unittest {
    // Small scientific notation
    assert(roundToSigFigs(1.23e-6) == 1.23e-6, "Expected small scientific notation 1.23e-6 to remain unchanged but got " ~ roundToSigFigs(1.23e-6).to!string);
    assert(roundToSigFigs(1.2345e-6) == 1.23e-6, "Expected 1.2345e-6 to round to 1.23e-6 (3 sig figs) but got " ~ roundToSigFigs(1.2345e-6).to!string);
    
    // Large scientific notation
    assert(roundToSigFigs(1.23e6) == 1.23e6, "Expected large scientific notation 1.23e6 to remain unchanged but got " ~ roundToSigFigs(1.23e6).to!string);
    assert(roundToSigFigs(1.2345e6) == 1.23e6, "Expected 1.2345e6 to round to 1.23e6 (3 sig figs) but got " ~ roundToSigFigs(1.2345e6).to!string);
}

// Test consistent precision across calculations
@("roundToSigFigs precision consistency")
unittest {
    // Test consistent precision with different representations
    double baseValue = 1234.5678;
    double rounded = roundToSigFigs(baseValue);
    assert(rounded == 1230.0, "Expected base value 1234.5678 to round to 1230.0 (3 sig figs) but got " ~ rounded.to!string);
    
    // Test derived calculations maintain precision
    double scaled = roundToSigFigs(baseValue * 2);
    assert(scaled == 2470.0, "Expected scaled value (1234.5678 * 2) to round to 2470.0 (3 sig figs) but got " ~ scaled.to!string);
    
    double inverse = roundToSigFigs(1.0 / baseValue);
    assert(isClose(inverse, 8.10e-4), "Expected inverse of 1234.5678 to round to approximately 8.130e-4 but got " ~ inverse.to!string);
}
