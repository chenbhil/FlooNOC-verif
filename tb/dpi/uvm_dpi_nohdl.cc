// -----------------------------------------------------------------------------
// UVM DPI-C helpers without the HDL backdoor.
//
// The kit's src/dpi/uvm_dpi.cc is this same list plus uvm_hdl.c, whose only
// backends are VCS, Questa and Xcelium (it #errors otherwise). The bench needs
// the regex and command-line helpers (config_db regex lookups, the component
// name check, +UVM_* argument parsing) but not the backdoor, so this file
// compiles the rest unmodified and the SV side keeps `UVM_HDL_NO_DPI.
// -----------------------------------------------------------------------------

#ifdef __cplusplus
extern "C" {
#endif

#include <stdlib.h>
#include "uvm_dpi.h"

// Avoid -Wmissing-definitions (same prototypes as uvm_dpi.cc, minus uvm_hdl_*)
 int uvm_re_match(const char * re, const char *str);
 const char * uvm_glob_to_re(const char *glob);
 void push_data(int lvl,char *entry, int cmd);
 void walk_level(int lvl, int argc, char**argv,int cmd);
 const char *uvm_dpi_get_next_arg_c (int init);
 extern char* uvm_dpi_get_tool_name_c ();
 extern char* uvm_dpi_get_tool_version_c ();
 extern regex_t* uvm_dpi_regcomp (char* pattern);
 extern int uvm_dpi_regexec (regex_t* re, char* str);
 extern void uvm_dpi_regfree (regex_t* re);

#include "uvm_common.c"
#include "uvm_regex.cc"
#include "uvm_svcmd_dpi.c"

#ifdef __cplusplus
}
#endif
