module test.bindings;

import bindings.ngspice;
import std.string : fromStringz, toStringz;
import std.math : approxEqual;

void setString(string value, out char* cString) {
    // Set the string value in the C struct
    cString = (value ~ '\0').dup.ptr;
}

// Test basic data structures
unittest {
    // Test ngcomplex structure
    ngcomplex complex = ngcomplex(1.0, 2.0);
    assert(complex.cx_real == 1.0);
    assert(complex.cx_imag == 2.0);

    // Test vector_info structure
    vector_info vec;
    setString("test", vec.v_name);
    vec.v_type = 1;
    vec.v_flags = 0;
    vec.v_length = 10;
    
    assert(vec.v_name.fromStringz == "test");
    assert(vec.v_type == 1);
    assert(vec.v_length == 10);

    // Test vecvalues structure
    vecvalues val;
    setString("voltage", val.name);
    val.real_value = 5.0;
    val.imag_value = -1.0;
    val.is_scale = false;
    val.is_complex = true;

    assert(val.name.fromStringz == "voltage");
    assert(val.real_value == 5.0);
    assert(val.imag_value == -1.0);
    assert(val.is_complex);
    assert(!val.is_scale);
}

// Test vector array handling
unittest {
    // Create test vector data
    double[] realData = [1.0, 2.0, 3.0];
    ngcomplex[] complexData = [
        ngcomplex(1.0, 1.0),
        ngcomplex(2.0, 2.0),
        ngcomplex(3.0, 3.0)
    ];

    vector_info vec;
    vec.v_length = cast(int)realData.length;
    vec.v_realdata = realData.ptr;
    
    // Test real data access
    assert(vec.v_realdata[0] == 1.0);
    assert(vec.v_realdata[1] == 2.0);
    assert(vec.v_realdata[2] == 3.0);

    // Test complex data access
    vec.v_compdata = complexData.ptr;
    assert(vec.v_compdata[0].cx_real == 1.0);
    assert(vec.v_compdata[0].cx_imag == 1.0);
    assert(vec.v_compdata[1].cx_real == 2.0);
    assert(vec.v_compdata[1].cx_imag == 2.0);
}

// Test vector info handling
unittest {
    vecinfoall plotInfo;
    
    // Set up basic plot info
    setString("tran1", plotInfo.name);
    setString("Transient Analysis", plotInfo.title);
    setString("Tue Apr 1", plotInfo.date);
    setString("time", plotInfo.type);
    plotInfo.veccount = 2;

    // Create vector infos
    vecinfo vector0;
    vecinfo vector1;
    vector0.number = 1;
    setString("time", vector0.vecname);
    vector0.is_real = true;

    vector1.number = 2;
    setString("v(out)", vector1.vecname);
    vector1.is_real = false;

    vecinfo*[2] vectors;
    vectors[0] = &vector0;
    vectors[1] = &vector1;
    plotInfo.vecs = vectors.ptr;

    // Test plot info access
    assert(plotInfo.name.fromStringz == "tran1");
    assert(plotInfo.title.fromStringz == "Transient Analysis");
    assert(plotInfo.type.fromStringz == "time");
    assert(plotInfo.veccount == 2);

    // Test vector info access
    assert(plotInfo.vecs[0].number == 1);
    assert(plotInfo.vecs[0].vecname.fromStringz == "time");
    assert(plotInfo.vecs[0].is_real);

    assert(plotInfo.vecs[1].number == 2);
    assert(plotInfo.vecs[1].vecname.fromStringz == "v(out)");
    assert(!plotInfo.vecs[1].is_real);
}
