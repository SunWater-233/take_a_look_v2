#include "window_input.h"

TalWindowInput::TalWindowInput(GtkWidget* view)
    : view_(view),
      window_(GTK_WINDOW(gtk_widget_get_toplevel(view))) {
  // Emission hooks run before FlView consumes the event. A normal connected
  // button handler never runs when FlView returns TRUE from its own handler.
  pointer_hook_ = g_signal_add_emission_hook(
      g_signal_lookup("button-press-event", GTK_TYPE_WIDGET), 0, PointerEvent,
      this, nullptr);
  touch_hook_ = g_signal_add_emission_hook(
      g_signal_lookup("touch-event", GTK_TYPE_WIDGET), 0, PointerEvent,
      this, nullptr);
  focus_handler_ = g_signal_connect_after(
      window_, "focus-in-event",
      G_CALLBACK(+[](GtkWidget*, GdkEventFocus*, gpointer data) -> gboolean {
        static_cast<TalWindowInput*>(data)->RestoreFocus();
        return FALSE;
      }), this);
  active_handler_ = g_signal_connect(
      window_, "notify::is-active",
      G_CALLBACK(+[](GObject*, GParamSpec*, gpointer data) {
        static_cast<TalWindowInput*>(data)->RestoreFocus();
      }), this);
  map_handler_ = g_signal_connect(
      view_, "map", G_CALLBACK(+[](GtkWidget*, gpointer data) {
        static_cast<TalWindowInput*>(data)->RestoreFocus();
      }), this);
}

TalWindowInput::~TalWindowInput() {
  g_signal_remove_emission_hook(
      g_signal_lookup("button-press-event", GTK_TYPE_WIDGET), pointer_hook_);
  g_signal_remove_emission_hook(
      g_signal_lookup("touch-event", GTK_TYPE_WIDGET), touch_hook_);
  g_signal_handler_disconnect(window_, focus_handler_);
  g_signal_handler_disconnect(window_, active_handler_);
  g_signal_handler_disconnect(view_, map_handler_);
  g_clear_pointer(&pointer_event_, gdk_event_free);
}

void TalWindowInput::RestoreFocus() {
  // Do not activate a window or override a native modal dialog. This only
  // chooses the keyboard recipient *inside* the already active Flutter window.
  if (!preview_ && gtk_window_get_accept_focus(window_) &&
      gtk_widget_get_mapped(view_) && gtk_window_is_active(window_) &&
      gtk_window_get_focus(window_) != view_) {
    gtk_widget_grab_focus(view_);
    if (g_getenv("TAL_WAYLAND_DRAG_DEBUG")) {
      g_message("GTK focus restored to Flutter view");
    }
  }
}

void TalWindowInput::SetPreview(bool preview) {
  preview_ = preview;
  gtk_window_set_accept_focus(window_, !preview);
  gtk_window_set_focus_on_map(window_, !preview);
  gtk_widget_set_can_focus(view_, !preview);
  if (preview) {
    gtk_window_set_focus(window_, nullptr);
  } else {
    RestoreFocus();
  }
}

GdkEvent* TalWindowInput::CopyPointerEvent() const {
  return pointer_event_ == nullptr ? nullptr : gdk_event_copy(pointer_event_);
}

void TalWindowInput::EndPointerSequence(GdkEvent* press) {
  if (!pointer_widget_) return;
  g_autoptr(GdkEvent) end = gdk_event_copy(press);
  const bool touch = press->type == GDK_TOUCH_BEGIN;
  end->type = touch ? GDK_TOUCH_CANCEL : GDK_BUTTON_RELEASE;
  gboolean handled = FALSE;
  // Use the widget that emitted the consumed signal. The event's native
  // window can instead belong to the child drawing area, which has no input
  // handler and therefore cannot complete Flutter's pointer sequence.
  g_signal_emit_by_name(pointer_widget_, touch ? "touch-event" : "button-release-event",
                        end, &handled);
}

gboolean TalWindowInput::PointerEvent(GSignalInvocationHint*, guint,
                                     const GValue* values, gpointer data) {
  auto* self = static_cast<TalWindowInput*>(data);
  auto* widget = GTK_WIDGET(g_value_get_object(values));
  if (widget != self->view_ && !gtk_widget_is_ancestor(widget, self->view_)) {
    return TRUE;
  }
  auto* event = static_cast<GdkEvent*>(g_value_get_boxed(values + 1));
  if (event != nullptr && (event->type == GDK_TOUCH_END || event->type == GDK_TOUCH_CANCEL)) {
    if (self->pointer_event_ != nullptr &&
        gdk_event_get_event_sequence(self->pointer_event_) == gdk_event_get_event_sequence(event)) {
      g_clear_pointer(&self->pointer_event_, gdk_event_free);
    }
  } else if (event != nullptr && (event->type == GDK_BUTTON_PRESS ||
                                  event->type == GDK_TOUCH_BEGIN)) {
    g_clear_pointer(&self->pointer_event_, gdk_event_free);
    self->pointer_event_ = gdk_event_copy(event);
    self->pointer_widget_ = widget;
    if (g_getenv("TAL_WAYLAND_DRAG_DEBUG")) {
      gdouble x = 0, y = 0;
      gdk_event_get_coords(event, &x, &y);
      g_message("GTK pointer press: window=%s widget=%s x=%.1f y=%.1f",
          gtk_window_get_title(self->window_), G_OBJECT_TYPE_NAME(widget), x, y);
    }
    self->RestoreFocus();
  }
  return TRUE;
}
