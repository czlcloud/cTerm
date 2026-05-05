#ifndef VTERM_H
#define VTERM_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct VTerm VTerm;
typedef struct VTermScreen VTermScreen;
typedef struct VTermState VTermState;

#define VTERM_MAX_CHARS_PER_CELL 6

typedef struct {
  int row;
  int col;
} VTermPos;

typedef struct {
  int start_row;
  int start_col;
  int end_row;
  int end_col;
} VTermRect;

typedef struct {
  uint8_t red, green, blue;
  uint8_t alpha;
} VTermColor;

typedef struct {
  uint8_t chars[VTERM_MAX_CHARS_PER_CELL];
  uint8_t widths[VTERM_MAX_CHARS_PER_CELL];
  VTermPos pos;
  VTermColor fg;
  VTermColor bg;
  uint32_t attrs;
  uint8_t dirty;
} VTermScreenCell;

#define VTERM_ATTR_BOLD          1
#define VTERM_ATTR_UNDERLINE     2
#define VTERM_ATTR_ITALIC        4
#define VTERM_ATTR_BLINK         8
#define VTERM_ATTR_REVERSE       16
#define VTERM_ATTR_STRIKETHROUGH 32

/* Callback structs */
typedef struct {
  int (*damage)(VTermRect rect, void *user);
  int (*moverect)(VTermRect dest, VTermRect src, void *user);
  int (*movecursor)(VTermPos pos, VTermPos oldpos, int visible, void *user);
  int (*settermprop)(int prop, void *val, void *user);
  int (*bell)(void *user);
  int (*resize)(int rows, int cols, void *user);
  int (*sb_pushline)(int cols, const VTermScreenCell *cells, void *user);
  int (*sb_popline)(int cols, VTermScreenCell *cells, void *user);
  int (*sb_clear)(void* user);
} VTermScreenCallbacks;

typedef void (*vterm_output_callback)(const char *bytes, size_t len, void *user);

/* Actual libvterm API */
VTerm *vterm_new(int rows, int cols);
void vterm_free(VTerm *vt);
VTermScreen *vterm_obtain_screen(VTerm *vt);
VTermState *vterm_obtain_state(VTerm *vt);
void vterm_input_write(VTerm *vt, const char *bytes, size_t len);
void vterm_screen_flush_damage(VTermScreen *screen);
void vterm_screen_get_cell(VTermScreen *screen, int row, int col, VTermScreenCell *cell);
void vterm_screen_set_callbacks(VTermScreen *screen, const VTermScreenCallbacks *callbacks, void *user);
void vterm_output_set_callback(VTerm *vt, vterm_output_callback cb, void *user);
void vterm_state_set_termprop(VTermState *state, int prop, int val);
void vterm_get_size(const VTerm *vt, int *rowsp, int *colsp);
void vterm_set_size(VTerm *vt, int rows, int cols);
void vterm_screen_reset(VTermScreen *screen, int hard);
void vterm_screen_enable_altscreen(VTermScreen *screen, int altscreen);

/* Wrapper functions (provide the simplified API our Swift code expects) */
void vterm_wrapper_set_damage_callback(VTermScreen *screen, void (*cb)(VTermRect rect, void *user), void *user);
void vterm_wrapper_set_output_callback(VTerm *vt, void (*cb)(const char *bytes, size_t len, void *user), void *user);
int vterm_wrapper_get_rows(VTerm *vt);
int vterm_wrapper_get_cols(VTerm *vt);
void vterm_wrapper_resize(VTerm *vt, VTermScreen *screen, int rows, int cols);

#endif
