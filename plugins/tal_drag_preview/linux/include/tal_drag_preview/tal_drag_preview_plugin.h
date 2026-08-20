#ifndef FLUTTER_PLUGIN_TAL_DRAG_PREVIEW_PLUGIN_H_
#define FLUTTER_PLUGIN_TAL_DRAG_PREVIEW_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

#define TAL_TYPE_DRAG_PREVIEW_PLUGIN tal_drag_preview_plugin_get_type()
G_DECLARE_FINAL_TYPE(TalDragPreviewPlugin, tal_drag_preview_plugin, TAL,
                     DRAG_PREVIEW_PLUGIN, GObject)

void tal_drag_preview_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

G_END_DECLS

#endif
