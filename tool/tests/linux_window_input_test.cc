#include "../../plugins/tal_drag_preview/linux/window_input.h"

static void Drain() {
  const gint64 until = g_get_monotonic_time() + 200000;
  do {
    while (g_main_context_iteration(nullptr, FALSE)) {}
    g_usleep(1000);
  } while (g_get_monotonic_time() < until);
}

int main(int argc, char** argv) {
  gtk_init(&argc, &argv);
  GtkWidget* window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  GtkWidget* view = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget* pointer = gtk_event_box_new();
  gtk_widget_set_can_focus(view, TRUE);
  gtk_container_add(GTK_CONTAINER(view), pointer);
  gtk_container_add(GTK_CONTAINER(window), view);
  // Match FlView: the first button handler consumes every pointer event.
  g_signal_connect(pointer, "button-press-event",
      G_CALLBACK(+[](GtkWidget*, GdkEventButton*, gpointer) -> gboolean {
        return TRUE;
      }), nullptr);
  int released = 0;
  g_signal_connect(pointer, "button-release-event",
      G_CALLBACK(+[](GtkWidget*, GdkEventButton*, gpointer data) -> gboolean {
        ++*static_cast<int*>(data);
        return TRUE;
      }), &released);
  {
    TalWindowInput input(view);
    gtk_widget_show_all(window);
    gtk_window_present(GTK_WINDOW(window));
    Drain();
    g_assert_true(gtk_window_is_active(GTK_WINDOW(window)));
    g_assert_true(gtk_window_get_focus(GTK_WINDOW(window)) == view);

    gtk_window_set_focus(GTK_WINDOW(window), nullptr);
    g_autoptr(GdkEvent) press = gdk_event_new(GDK_BUTTON_PRESS);
    press->button.window = GDK_WINDOW(g_object_ref(gtk_widget_get_window(pointer)));
    press->button.button = 1;
    press->button.time = GDK_CURRENT_TIME;
    gdk_event_set_device(press, gdk_seat_get_pointer(
        gdk_display_get_default_seat(gtk_widget_get_display(view))));
    gboolean handled = FALSE;
    g_signal_emit_by_name(pointer, "button-press-event", press, &handled);
    g_assert_true(handled);
    g_assert_true(gtk_window_get_focus(GTK_WINDOW(window)) == view);
    g_autoptr(GdkEvent) saved_press = input.CopyPointerEvent();
    g_assert_nonnull(saved_press);
    input.EndPointerSequence(saved_press);
    g_assert_cmpint(released, ==, 1);

    gtk_window_set_focus(GTK_WINDOW(window), nullptr);
    GdkEventFocus focus{};
    focus.type = GDK_FOCUS_CHANGE;
    focus.in = TRUE;
    g_signal_emit_by_name(window, "focus-in-event", &focus, &handled);
    g_assert_true(gtk_window_get_focus(GTK_WINDOW(window)) == view);

    input.SetPreview(true);
    g_assert_false(gtk_window_get_accept_focus(GTK_WINDOW(window)));
    g_assert_false(gtk_window_get_focus_on_map(GTK_WINDOW(window)));
    g_assert_false(gtk_widget_get_can_focus(view));
    g_signal_emit_by_name(pointer, "button-press-event", press, &handled);
    g_assert_null(gtk_window_get_focus(GTK_WINDOW(window)));
    input.SetPreview(false);
    g_assert_true(gtk_window_get_accept_focus(GTK_WINDOW(window)));
    g_assert_true(gtk_window_get_focus_on_map(GTK_WINDOW(window)));
    g_assert_true(gtk_window_get_focus(GTK_WINDOW(window)) == view);

    GtkWidget* dialog = gtk_dialog_new();
    gtk_window_set_transient_for(GTK_WINDOW(dialog), GTK_WINDOW(window));
    gtk_window_set_modal(GTK_WINDOW(dialog), TRUE);
    gtk_widget_show(dialog);
    gtk_window_present(GTK_WINDOW(dialog));
    Drain();
    g_assert_true(gtk_window_is_active(GTK_WINDOW(dialog)));
    gtk_window_set_focus(GTK_WINDOW(window), nullptr);
    input.RestoreFocus();
    g_assert_null(gtk_window_get_focus(GTK_WINDOW(window)));
    g_assert_true(gtk_window_is_active(GTK_WINDOW(dialog)));
    gtk_widget_destroy(dialog);
    gtk_window_present(GTK_WINDOW(window));
    Drain();
    g_assert_true(gtk_window_get_focus(GTK_WINDOW(window)) == view);

    gtk_widget_hide(window);
    gtk_window_set_focus(GTK_WINDOW(window), nullptr);
    gtk_widget_show(window);
    gtk_window_present(GTK_WINDOW(window));
    Drain();
    g_assert_true(gtk_window_get_focus(GTK_WINDOW(window)) == view);
  }
  gtk_widget_destroy(window);
  Drain();
  g_print("Linux GTK input: consumed-click recovery, activation, remap, preview exclusion, modal ownership passed.\n");
  return 0;
}
