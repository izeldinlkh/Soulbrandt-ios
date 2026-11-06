#include "ps3emu/ppu_lift.h"

/* The host scaffold can be linked and exercised before game-derived lift code
 * is available. This empty table is replaced by the real generated table in a
 * game-enabled build; it deliberately makes ppu_run unusable for a real title. */
#if !defined(SOULBRANDT_HAS_GAME_LIFT)
extern "C" {
extern const func_entry function_table[] = {{0, nullptr, nullptr}};
extern const uint64_t function_table_count = 0;
}
#endif
