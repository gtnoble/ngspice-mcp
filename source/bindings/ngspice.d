/**
 * D bindings for ngspice shared library interface.
 *
 * This module provides D declarations for the ngspice C API defined in sharedspice.h.
 * It enables D applications to interact with ngspice's simulation capabilities.
 */
module bindings.ngspice;

extern(C) enum simulation_types {
  SV_NOTYPE,
  SV_TIME,
  SV_FREQUENCY,
  SV_VOLTAGE,
  SV_CURRENT,
  SV_VOLTAGE_DENSITY,
  SV_CURRENT_DENSITY,
  SV_SQR_VOLTAGE_DENSITY,
  SV_SQR_CURRENT_DENSITY,
  SV_SQR_VOLTAGE,
  SV_SQR_CURRENT,
  SV_POLE,
  SV_ZERO,
  SV_SPARAM,
  SV_TEMP,
  SV_RES,
  SV_IMPEDANCE,
  SV_ADMITTANCE,
  SV_POWER,
  SV_PHASE,
  SV_DB,
  SV_CAPACITANCE,
  SV_CHARGE
}

extern(C) enum PLOTTYPE {
    PLOT_LIN, 
    PLOT_COMB, 
    PLOT_POINT, 
    PLOT_RETLIN
}

extern(C) enum GRIDTYPE {
    GRID_NONE, 
    GRID_LIN, 
    GRID_LOGLOG, 
    GRID_XLOG, 
    GRID_YLOG,
    GRID_POLAR, 
    GRID_SMITH, 
    GRID_SMITHGRID, 
    GRID_DIGITAL_NONE,
    GRID_DIGITAL
}

/// Complex number type used by ngspice
extern(C) struct ngcomplex
{
    double cx_real;
    double cx_imag;
}

alias ngcomplex_t = ngcomplex;

/// Vector info structure for accessing simulation data
extern(C) struct vector_info
{
    char* v_name;      /// Same as so_vname
    simulation_types v_type;        /// Same as so_vtype
    short v_flags;     /// Flags (combination of VF_*)
    double* v_realdata;  /// Real data
    ngcomplex_t* v_compdata; /// Complex data
    int v_length;     /// Length of the vector
}

alias vector_info_ptr = vector_info*;

/// Structure for vector values in callbacks
extern(C) struct vecvalues
{
    char* name;        /// Name of specific vector
    double real_value;      /// Actual data value (real part)
    double imag_value;      /// Actual data value (imaginary part)
    bool is_scale;     /// If 'name' is the scale vector
    bool is_complex;   /// If the data are complex numbers
}

alias vecvalues_ptr = vecvalues*;

/// Structure for all vector values in a plot
extern(C) struct vecvaluesall
{
    int veccount;      /// Number of vectors in plot
    int vecindex;      /// Index of actual set of vectors
    vecvalues_ptr* vecsa; /// Values of actual set of vectors
}

alias vecvaluesall_ptr = vecvaluesall*;

/// Information about a specific vector
extern(C) struct vecinfo
{
    int number;          /// Position in linked list of vectors
    char* vecname;       /// Name of the vector
    bool is_real;        /// TRUE if vector has real data
    dvec* pdvec;         /// Void pointer to struct dvec
    dvec* pdvecscale;    /// Void pointer to scale vector
}

alias vecinfo_ptr = vecinfo*;

/// Information about the current plot
extern(C) struct vecinfoall
{
    char* name;    /// Plot name
    char* title;   /// Plot title
    char* date;    /// Plot date
    char* type;    /// Plot type
    int veccount;  /// Number of vectors
    vecinfo_ptr* vecs; /// Array of vector info
}
extern (C) struct dvec {
    char *v_name; /* Same as so_vname. */
    simulation_types v_type; /* Same as so_vtype. */
    short v_flags; /* Flags (a combination of VF_*). */
    double *v_realdata; /* Real data. */
    ngcomplex_t *v_compdata; /* Complex data. */
    double v_minsignal; /* Minimum value to plot. */
    double v_maxsignal; /* Maximum value to plot. */
    GRIDTYPE v_gridtype; /* One of GRID_*. */
    PLOTTYPE v_plottype; /* One of PLOT_*. */
    int v_length; /* Length of the vector. */
    int v_alloc_length; /* How much has been actually allocated. */
    int v_rlength; /* How much space we really have. Used as binary flag */
    int v_outindex; /* Index if writedata is building the vector. */
    int v_linestyle; /* What line style we are using. */
    int v_color; /* What color we are using. */
    char *v_defcolor; /* The name of a color to use. */
    int v_numdims; /* How many dims -- 0 = scalar (len = 1). */
    int[8] v_dims; /* The actual size in each dimension. */
    void *v_plot; /* The plot structure (if it has one). */
    dvec *v_next; /* Link for list of plot vectors. */
    dvec *v_link2; /* Extra link for things like print. */
    dvec *v_scale; /* If this has a non-standard scale... */
}

alias vecinfoall_ptr = vecinfoall*;

// Callback function types
alias SendChar = extern(C) int function(char* str, int id, void* user_data);
alias SendStat = extern(C) int function(char* str, int id, void* user_data);
alias ControlledExit = extern(C) int function(int status, bool immediate, bool exit_upon_quit, int id, void* user_data);
alias SendData = extern(C) int function(vecvaluesall_ptr data, int count, int id, void* user_data);
alias SendInitData = extern(C) int function(vecinfoall_ptr data, int id, void* user_data);
alias BGThreadRunning = extern(C) int function(bool running, int id, void* user_data);

// External functions from ngspice shared library
extern(C) int ngSpice_Init(
    SendChar printfcn,
    SendStat statfcn, 
    ControlledExit ngexit,
    SendData sdata, 
    SendInitData sinitdata,
    BGThreadRunning bgtrun,
    void* user_data
);

extern(C) {
    int ngSpice_Command(const char* command);
    vector_info_ptr ngGet_Vec_Info(const char* vec_name);
    int ngSpice_Circ(char** circuit_array);
    char* ngSpice_CurPlot();
    char** ngSpice_AllPlots();
    char** ngSpice_AllVecs(const char* plot_name);
    int ngSpice_running();
    bool ngSpice_SetBkpt(double time);
}
