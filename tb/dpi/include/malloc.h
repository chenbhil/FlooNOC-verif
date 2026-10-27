// macOS has no <malloc.h>; the kit's uvm_dpi.h includes it only for malloc()
// and free(), which <stdlib.h> declares. Only on the include path of the
// UVM DPI build (scripts/run_verilator.sh).
#include <stdlib.h>
