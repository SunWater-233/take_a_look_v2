#include "include/tal_drag_preview/tal_drag_preview_plugin.h"

#include <gtk/gtk.h>

struct _TalDragPreviewPlugin {
  GObject parent_instance;
  FlView* view;
};

G_DEFINE_TYPE(TalDragPreviewPlugin, tal_drag_preview_plugin, G_TYPE_OBJECT)

static void set_click_through(TalDragPreviewPlugin* self, gboolean enabled) {
  GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(self->view));
  gtk_widget_realize(toplevel);
  GdkWindow* window = gtk_widget_get_window(toplevel);
  if (window == nullptr) return;
  if (enabled) {
    cairo_region_t* empty = cairo_region_create();
    gdk_window_input_shape_combine_region(window, empty, 0, 0);
    cairo_region_destroy(empty);
  } else {
    gdk_window_input_shape_combine_region(window, nullptr, 0, 0);
  }
}

static void handle_method_call(TalDragPreviewPlugin* self,
                               FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(fl_method_call_get_name(method_call), "setClickThrough") != 0) {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  } else {
    FlValue* arguments = fl_method_call_get_args(method_call);
    FlValue* enabled = fl_value_lookup_string(arguments, "enabled");
    if (enabled == nullptr || fl_value_get_type(enabled) != FL_VALUE_TYPE_BOOL) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "invalid_arguments", "Expected enabled boolean", nullptr));
    } else {
      set_click_through(self, fl_value_get_bool(enabled));
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  }
  fl_method_call_respond(method_call, response, nullptr);
}

static void tal_drag_preview_plugin_dispose(GObject* object) {
  G_OBJECT_CLASS(tal_drag_preview_plugin_parent_class)->dispose(object);
}

static void tal_drag_preview_plugin_class_init(
    TalDragPreviewPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = tal_drag_preview_plugin_dispose;
}

static void tal_drag_preview_plugin_init(TalDragPreviewPlugin* self) {
  (void)self;
}

void tal_drag_preview_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  TalDragPreviewPlugin* plugin = TAL_DRAG_PREVIEW_PLUGIN(
      g_object_new(tal_drag_preview_plugin_get_type(), nullptr));
  plugin->view = fl_plugin_registrar_get_view(registrar);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "take_a_look/drag_preview_window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel,
      [](FlMethodChannel*, FlMethodCall* call, gpointer user_data) {
        handle_method_call(TAL_DRAG_PREVIEW_PLUGIN(user_data), call);
      },
      g_object_ref(plugin), g_object_unref);
  g_object_unref(plugin);
}
