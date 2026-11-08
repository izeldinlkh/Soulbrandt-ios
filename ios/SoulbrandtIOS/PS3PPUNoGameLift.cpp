#include <stdint.h>

// Keep the no-game fallback's table layout identical to the macOS lifter's
// HEADER_PREAMBLE. The generated header supplies the complete ppu_context;
// this fallback only needs an ABI-compatible function pointer declaration.
struct ppu_context;
typedef struct {
    uint64_t addr;
    void (*func)(ppu_context*);
    const char* name;
} func_entry;

/* The no-game build still needs a table so the PPU host can link. The
 * generated game-lift archive is force-loaded when present; its strong table
 * definitions override these weak empty defaults. */
extern "C" {
__attribute__((weak)) const func_entry function_table[] = {{0, nullptr, nullptr}};
__attribute__((weak)) const uint64_t function_table_count = 0;
}
