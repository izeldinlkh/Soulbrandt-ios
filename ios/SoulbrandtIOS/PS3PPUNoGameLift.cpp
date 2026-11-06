#include "ps3emu/ppu_lift.h"

/* The no-game build still needs a table so the PPU host can link. The
 * generated game-lift archive is force-loaded when present; its strong table
 * definitions override these weak empty defaults. */
extern "C" {
__attribute__((weak)) const func_entry function_table[] = {{0, nullptr, nullptr}};
__attribute__((weak)) const uint64_t function_table_count = 0;
}
