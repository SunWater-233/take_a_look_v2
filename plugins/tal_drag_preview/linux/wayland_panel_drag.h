#ifndef TAL_WAYLAND_PANEL_DRAG_H_
#define TAL_WAYLAND_PANEL_DRAG_H_
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include "window_input.h"

// Uses the press serial from its own Wayland pointer/touch listener. GTK 3
// otherwise substitutes a later keyboard-focus serial on an unfocused window.
void TalWaylandDragRegister(FlView* view, FlMethodChannel* channel);
void TalWaylandDragUnregister(FlView* view);
void TalWaylandDragBegin(FlView* view, TalWindowInput* input, FlMethodCall* call);
#endif

