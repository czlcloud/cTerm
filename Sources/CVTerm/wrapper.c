#include "include/vterm.h"
#include <stdlib.h>

// No-op callbacks to prevent NULL pointer dereference in libvterm
static int noop_int_rect(VTermRect rect, void *user) { (void)rect; (void)user; return 1; }
static int noop_int_rect_rect(VTermRect dest, VTermRect src, void *user) { (void)dest; (void)src; (void)user; return 1; }
static int noop_int_pos_pos_int(VTermPos pos, VTermPos oldpos, int visible, void *user) { (void)pos; (void)oldpos; (void)visible; (void)user; return 1; }
static int noop_int_prop_value(int prop, void *val, void *user) { (void)prop; (void)val; (void)user; return 1; }
static int noop_bell(void *user) { (void)user; return 1; }
static int noop_resize(int rows, int cols, void *user) { (void)rows; (void)cols; (void)user; return 1; }
static int noop_sb_push(int cols, const VTermScreenCell *cells, void *user) { (void)cols; (void)cells; (void)user; return 1; }
static int noop_sb_pop(int cols, VTermScreenCell *cells, void *user) { (void)cols; (void)cells; (void)user; return 1; }
static int noop_sb_clear(void *user) { (void)user; return 1; }

void vterm_wrapper_set_damage_callback(VTermScreen *screen, void (*cb)(VTermRect rect, void *user), void *user) {
    VTermScreenCallbacks cbs = {0};
    cbs.damage = (int (*)(VTermRect, void*))cb;
    cbs.moverect = noop_int_rect_rect;
    cbs.movecursor = noop_int_pos_pos_int;
    cbs.settermprop = noop_int_prop_value;
    cbs.bell = noop_bell;
    cbs.resize = noop_resize;
    cbs.sb_pushline = noop_sb_push;
    cbs.sb_popline = noop_sb_pop;
    cbs.sb_clear = noop_sb_clear;
    vterm_screen_set_callbacks(screen, &cbs, user);
}

void vterm_wrapper_set_output_callback(VTerm *vt, void (*cb)(const char *bytes, size_t len, void *user), void *user) {
    vterm_output_set_callback(vt, (vterm_output_callback)cb, user);
}

int vterm_wrapper_get_rows(VTerm *vt) {
    int rows = 0, cols = 0;
    vterm_get_size(vt, &rows, &cols);
    return rows;
}

int vterm_wrapper_get_cols(VTerm *vt) {
    int rows = 0, cols = 0;
    vterm_get_size(vt, &rows, &cols);
    return cols;
}

void vterm_wrapper_resize(VTerm *vt, VTermScreen *screen, int rows, int cols) {
    vterm_set_size(vt, rows, cols);
    vterm_screen_reset(screen, 1);
}
