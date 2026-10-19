#include "include/tal_drag_preview/tal_drag_preview_plugin.h"
#include <gtk/gtk.h>
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif
#include <cstring>
#include "window_input.h"
#include "wayland_panel_drag.h"

struct _TalDragPreviewPlugin {
  GObject parent_instance;
  FlView* view;
  FlMethodChannel* channel;
  TalWindowInput* input;
  bool wayland_registered;
};
G_DEFINE_TYPE(TalDragPreviewPlugin, tal_drag_preview_plugin, G_TYPE_OBJECT)

static bool is_wayland(TalDragPreviewPlugin* self) {
#ifdef GDK_WINDOWING_WAYLAND
  return GDK_IS_WAYLAND_DISPLAY(gtk_widget_get_display(GTK_WIDGET(self->view)));
#else
  return false;
#endif
}
static void set_click_through(TalDragPreviewPlugin* self, gboolean enabled) {
  self->input->SetPreview(enabled);
  GtkWidget* top = gtk_widget_get_toplevel(GTK_WIDGET(self->view));
  gtk_widget_realize(top);
  GdkWindow* window = gtk_widget_get_window(top);
  if (!window) return;
  if (enabled) {
    cairo_region_t* empty = cairo_region_create();
    gdk_window_input_shape_combine_region(window, empty, 0, 0);
    cairo_region_destroy(empty);
  } else {
    gdk_window_input_shape_combine_region(window, nullptr, 0, 0);
  }
}
static void handle_method(TalDragPreviewPlugin* self, FlMethodCall* call) {
  const char* method = fl_method_call_get_name(call);
  if (!strcmp(method, "beginTabDrag")) {
    TalWaylandDragBegin(self->view, self->input, call);
    return;
  }
  g_autoptr(FlMethodResponse) response = nullptr;
  if (!strcmp(method, "getCapabilities")) {
    g_autoptr(FlValue) value = fl_value_new_map();
    fl_value_set_string_take(value, "nativeWayland", fl_value_new_bool(is_wayland(self)));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  } else if (!strcmp(method, "setClickThrough")) {
    FlValue* arguments = fl_method_call_get_args(call);
    FlValue* enabled = arguments ? fl_value_lookup_string(arguments, "enabled") : nullptr;
    if (!enabled || fl_value_get_type(enabled) != FL_VALUE_TYPE_BOOL) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "invalid_arguments", "Expected enabled boolean", nullptr));
    } else {
      set_click_through(self, fl_value_get_bool(enabled));
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}
static void tal_drag_preview_plugin_dispose(GObject* object) {
  auto* self = TAL_DRAG_PREVIEW_PLUGIN(object);
  if (self->wayland_registered) {
    TalWaylandDragUnregister(self->view);
    self->wayland_registered = false;
  }
  delete self->input;
  self->input = nullptr;
  g_clear_object(&self->channel);
  G_OBJECT_CLASS(tal_drag_preview_plugin_parent_class)->dispose(object);
}
static void tal_drag_preview_plugin_class_init(TalDragPreviewPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = tal_drag_preview_plugin_dispose;
}
static void tal_drag_preview_plugin_init(TalDragPreviewPlugin*) {}
void tal_drag_preview_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  auto* plugin = TAL_DRAG_PREVIEW_PLUGIN(
      g_object_new(tal_drag_preview_plugin_get_type(), nullptr));
  plugin->view = fl_plugin_registrar_get_view(registrar);
  plugin->input = new TalWindowInput(GTK_WIDGET(plugin->view));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
      "take_a_look/drag_preview_window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(plugin->channel,
      [](FlMethodChannel*, FlMethodCall* call, gpointer data) {
        handle_method(TAL_DRAG_PREVIEW_PLUGIN(data), call);
      }, plugin, nullptr);
  if (is_wayland(plugin)) {
    TalWaylandDragRegister(plugin->view, plugin->channel);
    plugin->wayland_registered = true;
  }
  if (g_getenv("TAL_WAYLAND_DRAG_DEBUG")) {
    g_signal_connect_object(plugin->view, "drag-data-received", G_CALLBACK(
        +[](GtkWidget*, GdkDragContext*, gint x, gint y, GtkSelectionData* data,
            guint, guint, gpointer) {
          g_message("GTK file drop data: bytes=%d x=%d y=%d",
              gtk_selection_data_get_length(data), x, y);
        }), plugin, static_cast<GConnectFlags>(0));
  }
  g_signal_connect(plugin->view, "destroy", G_CALLBACK(+[](GtkWidget*, gpointer data) {
    g_object_run_dispose(G_OBJECT(data));
  }), plugin);
  g_object_set_data_full(G_OBJECT(plugin->view), "take-a-look-native-window",
                         plugin, g_object_unref);
}
