#include "wayland_panel_drag.h"
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#include <wayland-client.h>
#include <sys/mman.h>
#include <unistd.h>
#include <algorithm>
#include <cstring>
#include <memory>
#include <vector>

namespace {
constexpr char kMime[] = "application/x-take-a-look-panel";
constexpr char kBackend[] = "take-a-look-wayland-drag";

struct Entry {
  FlView* view;
  FlMethodChannel* channel;
  GtkTargetList* file_targets = nullptr;
  gulong drop_handler = 0;
  bool armed = false;
};
struct Offer {
  wl_data_offer* proxy;
  bool panel = false;
  bool dropped = false;
  explicit Offer(wl_data_offer* value) : proxy(value) {}
  ~Offer() { if (proxy) wl_data_offer_destroy(proxy); }
};
struct Source {
  wl_data_source* proxy = nullptr;
  wl_surface* icon = nullptr;
  wl_buffer* buffer = nullptr;
  wl_shm_pool* pool = nullptr;
  int fd = -1;
  void* pixels = MAP_FAILED;
  size_t size = 0;
  FlMethodCall* call = nullptr;
  FlValue* payload = nullptr;
  FlView* view = nullptr;
  ~Source() {
    if (proxy) wl_data_source_destroy(proxy);
    if (icon) wl_surface_destroy(icon);
    if (buffer) wl_buffer_destroy(buffer);
    if (pool) wl_shm_pool_destroy(pool);
    if (pixels != MAP_FAILED) munmap(pixels, size);
    if (fd >= 0) close(fd);
    g_clear_object(&call);
    g_clear_pointer(&payload, fl_value_unref);
  }
};

class Backend {
 public:
  explicit Backend(GdkDisplay* display) : display_(display) {}
  ~Backend() { Stop(); }

  void Register(FlView* view, FlMethodChannel* channel) {
    entries_.push_back(std::unique_ptr<Entry>(new Entry{view, channel}));
    if (!queue_) Init();
    if (source_) Arm(*entries_.back());
  }

  void Unregister(FlView* view) {
    if (source_ && source_->view == view) Finish("cancelled");
    if (target_ && target_->view == view) target_ = nullptr;
    for (const auto& entry : entries_) if (entry->view == view) Restore(*entry);
    entries_.erase(std::remove_if(entries_.begin(), entries_.end(),
        [view](const std::unique_ptr<Entry>& entry) { return entry->view == view; }),
        entries_.end());
    if (entries_.empty()) Stop();
  }

  void Begin(FlView* view, TalWindowInput* input, FlMethodCall* call) {
    Pump();
    FlValue* arguments = fl_method_call_get_args(call);
    FlValue* payload = arguments ? fl_value_lookup_string(arguments, "payload") : nullptr;
    g_autoptr(GdkEvent) press = input->CopyPointerEvent();
    const bool touch = press && press->type == GDK_TOUCH_BEGIN;
    uint32_t serial = touch ? touch_serial_ : pointer_serial_;
    if (g_getenv("TAL_WAYLAND_DRAG_DEBUG")) {
      g_message("Native panel drag: device=%d pointer=%d touch=%d serial=%u event=%d",
          manager_ != nullptr, pointer_pressed_, touch_pressed_, serial, press != nullptr);
    }
    if (!manager_ || !seat_ || source_ || !press || !payload ||
        fl_value_get_type(payload) != FL_VALUE_TYPE_MAP ||
        !(touch ? touch_pressed_ : pointer_pressed_) || serial == 0) {
      Respond(call, "cancelled");
      return;
    }
    source_.reset(new Source());
    source_->view = view;
    source_->call = FL_METHOD_CALL(g_object_ref(call));
    source_->payload = fl_value_ref(payload);
    // Only subscribe a second data-device while dragging one of our panels.
    // External file drops keep GDK as the sole destination/device owner.
    device_ = wl_data_device_manager_get_data_device(manager_, seat_);
    InitDeviceListener();
    source_->proxy = wl_data_device_manager_create_data_source(manager_);
    for (const auto& entry : entries_) Arm(*entry);
    static const wl_data_source_listener listener = {
      +[](void*, wl_data_source*, const char*) {},
      +[](void*, wl_data_source*, const char*, int32_t fd) { close(fd); },
      +[](void* data, wl_data_source*) { static_cast<Backend*>(data)->Finish("cancelled"); },
      +[](void*, wl_data_source*) {},
      +[](void* data, wl_data_source*) { static_cast<Backend*>(data)->Finish("dropped"); },
      +[](void*, wl_data_source*, uint32_t) {},
    };
    wl_data_source_add_listener(source_->proxy, &listener, this);
    wl_data_source_offer(source_->proxy, kMime);
    wl_data_source_set_actions(source_->proxy, WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE);
    CreateIcon(arguments, view);

    // The compositor consumes the real release. Complete Flutter's sequence
    // now, without changing the real Wayland press or its implicit grab.
    input->EndPointerSequence(press);
    GtkWidget* window = gtk_widget_get_toplevel(GTK_WIDGET(view));
    wl_surface* origin = gdk_wayland_window_get_wl_surface(gtk_widget_get_window(window));
    wl_data_device_start_drag(device_, source_->proxy, origin, source_->icon, serial);
    // The compositor now owns this gesture. Release GDK's implicit grab too,
    // otherwise later clicks on a different FlView can be routed to the origin.
    gdk_seat_ungrab(gdk_display_get_default_seat(display_));
    wl_display_flush(connection_);
    SchedulePump();
  }

 private:
  GdkDisplay* display_;
  wl_display* connection_ = nullptr;
  wl_event_queue* queue_ = nullptr;
  wl_registry* registry_ = nullptr;
  wl_compositor* compositor_ = nullptr;
  wl_shm* shm_ = nullptr;
  wl_data_device_manager* manager_ = nullptr;
  wl_data_device* device_ = nullptr;
  wl_seat* seat_ = nullptr;
  wl_pointer* pointer_ = nullptr;
  wl_touch* touch_ = nullptr;
  guint pump_ = 0;
  bool stopping_ = false;
  uint32_t pointer_serial_ = 0, touch_serial_ = 0, enter_serial_ = 0;
  bool pointer_pressed_ = false, touch_pressed_ = false;
  int32_t touch_id_ = -1;
  std::vector<std::unique_ptr<Entry>> entries_;
  std::vector<std::shared_ptr<Offer>> offers_;
  std::unique_ptr<Source> source_;
  std::shared_ptr<Offer> offer_;
  Entry* target_ = nullptr;
  double x_ = 0, y_ = 0;

  static void Respond(FlMethodCall* call, const char* result) {
    g_autoptr(FlValue) value = fl_value_new_string(result);
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(value));
    fl_method_call_respond(call, response, nullptr);
  }
  void Finish(const char* result) {
    if (!source_) return;
    // A compositor may cancel the source before sending the destination's
    // leave. Notify while the payload still exists so remote feedback clears.
    Notify("leave", false);
    Respond(source_->call, result);
    source_.reset();
    for (const auto& entry : entries_) Restore(*entry);
    target_ = nullptr;
    offer_.reset();
    offers_.clear();
    if (device_) { wl_data_device_release(device_); device_ = nullptr; }
    pointer_pressed_ = false;
    touch_pressed_ = false;
    SchedulePump();
  }
  void Arm(Entry& entry) {
    if (entry.armed) return;
    auto* view = GTK_WIDGET(entry.view);
    entry.file_targets = gtk_drag_dest_get_target_list(view);
    if (entry.file_targets) gtk_target_list_ref(entry.file_targets);
    GtkTargetEntry target = {const_cast<char*>(kMime), 0, 0};
    // GDK has a second data-device on the same seat. During our drag, its
    // normal file destination must agree on MOVE instead of rejecting the
    // private MIME and overriding the native device's accepted action.
    gtk_drag_dest_set(view, GTK_DEST_DEFAULT_MOTION, &target, 1, GDK_ACTION_MOVE);
    entry.drop_handler = g_signal_connect(view, "drag-drop", G_CALLBACK(
        +[](GtkWidget*, GdkDragContext*, gint, gint, guint, gpointer) -> gboolean {
          // The native offer is finished only after Dart commits the transfer.
          return TRUE;
        }), nullptr);
    entry.armed = true;
  }
  void Restore(Entry& entry) {
    if (!entry.armed) return;
    auto* view = GTK_WIDGET(entry.view);
    g_signal_handler_disconnect(view, entry.drop_handler);
    if (entry.file_targets) {
      gtk_drag_dest_set(view, GTK_DEST_DEFAULT_ALL, nullptr, 0, GDK_ACTION_COPY);
      gtk_drag_dest_set_target_list(view, entry.file_targets);
      gtk_target_list_unref(entry.file_targets);
      entry.file_targets = nullptr;
    } else {
      gtk_drag_dest_unset(view);
    }
    entry.armed = false;
  }
  void Pump() {
    if (queue_ && wl_display_dispatch_queue_pending(connection_, queue_) < 0) {
      Finish("cancelled");
    }
    if (connection_) wl_display_flush(connection_);
  }
  void SchedulePump() {
    if (stopping_ || !queue_) return;
    if (pump_) g_source_remove(pump_);
    pump_ = g_timeout_add(source_ ? 5 : 50, +[](gpointer data) -> gboolean {
      auto* self = static_cast<Backend*>(data);
      self->pump_ = 0;
      self->Pump();
      self->SchedulePump();
      return G_SOURCE_REMOVE;
    }, this);
  }
  void Init() {
    stopping_ = false;
    connection_ = gdk_wayland_display_get_wl_display(display_);
    queue_ = wl_display_create_queue(connection_);
    registry_ = wl_display_get_registry(connection_);
    wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(registry_), queue_);
    static const wl_registry_listener registry_listener = {
      +[](void* data, wl_registry* registry, uint32_t name, const char* interface, uint32_t version) {
        auto* self = static_cast<Backend*>(data);
        if (!strcmp(interface, wl_compositor_interface.name))
          self->compositor_ = static_cast<wl_compositor*>(wl_registry_bind(registry, name, &wl_compositor_interface, std::min(version, 3u)));
        else if (!strcmp(interface, wl_shm_interface.name))
          self->shm_ = static_cast<wl_shm*>(wl_registry_bind(registry, name, &wl_shm_interface, 1));
        else if (!strcmp(interface, wl_data_device_manager_interface.name) && version >= 3)
          self->manager_ = static_cast<wl_data_device_manager*>(wl_registry_bind(registry, name, &wl_data_device_manager_interface, 3));
        else if (!strcmp(interface, wl_seat_interface.name) && !self->seat_) {
          // Bound version 5 keeps the pointer/touch listener ABI compatible
          // with the oldest GTK/Wayland headers supported by the package.
          self->seat_ = static_cast<wl_seat*>(wl_registry_bind(registry, name, &wl_seat_interface, std::min(version, 5u)));
          static const wl_seat_listener seat_listener = {
            +[](void* data, wl_seat*, uint32_t caps) { static_cast<Backend*>(data)->BindInput(caps); },
            +[](void*, wl_seat*, const char*) {},
          };
          wl_seat_add_listener(self->seat_, &seat_listener, self);
        }
      },
      +[](void*, wl_registry*, uint32_t) {},
    };
    wl_registry_add_listener(registry_, &registry_listener, this);
    wl_display_roundtrip_queue(connection_, queue_);
    if (!manager_ || !seat_) return;
    SchedulePump();
    wl_display_flush(connection_);
  }
  void BindInput(uint32_t caps) {
    static const wl_pointer_listener pointer_listener = {
      +[](void*, wl_pointer*, uint32_t, wl_surface*, wl_fixed_t, wl_fixed_t) {},
      +[](void*, wl_pointer*, uint32_t, wl_surface*) {},
      +[](void*, wl_pointer*, uint32_t, wl_fixed_t, wl_fixed_t) {},
      +[](void* data, wl_pointer*, uint32_t serial, uint32_t, uint32_t button, uint32_t state) {
        auto* self = static_cast<Backend*>(data);
        if (button != 0x110) return;
        self->pointer_pressed_ = state == WL_POINTER_BUTTON_STATE_PRESSED;
        if (self->pointer_pressed_) self->pointer_serial_ = serial;
      },
      +[](void*, wl_pointer*, uint32_t, uint32_t, wl_fixed_t) {},
      +[](void*, wl_pointer*) {},
      +[](void*, wl_pointer*, uint32_t) {},
      +[](void*, wl_pointer*, uint32_t, uint32_t) {},
      +[](void*, wl_pointer*, uint32_t, int32_t) {},
    };
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !pointer_) {
      pointer_ = wl_seat_get_pointer(seat_);
      wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(pointer_), queue_);
      wl_pointer_add_listener(pointer_, &pointer_listener, this);
    }
    static const wl_touch_listener touch_listener = {
      +[](void* data, wl_touch*, uint32_t serial, uint32_t, wl_surface*, int32_t id, wl_fixed_t, wl_fixed_t) {
        auto* self = static_cast<Backend*>(data);
        if (!self->touch_pressed_) { self->touch_pressed_ = true; self->touch_id_ = id; self->touch_serial_ = serial; }
      },
      +[](void* data, wl_touch*, uint32_t, uint32_t, int32_t id) {
        auto* self = static_cast<Backend*>(data);
        if (self->touch_id_ == id) self->touch_pressed_ = false;
      },
      +[](void*, wl_touch*, uint32_t, int32_t, wl_fixed_t, wl_fixed_t) {},
      +[](void*, wl_touch*) {},
      +[](void* data, wl_touch*) { static_cast<Backend*>(data)->touch_pressed_ = false; },
      +[](void*, wl_touch*, int32_t, wl_fixed_t, wl_fixed_t) {},
      +[](void*, wl_touch*, int32_t, wl_fixed_t) {},
    };
    if ((caps & WL_SEAT_CAPABILITY_TOUCH) && !touch_) {
      touch_ = wl_seat_get_touch(seat_);
      wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(touch_), queue_);
      wl_touch_add_listener(touch_, &touch_listener, this);
    }
  }
  void InitDeviceListener() {
    static const wl_data_device_listener device_listener = {
      +[](void* data, wl_data_device*, wl_data_offer* proxy) {
        auto* self = static_cast<Backend*>(data);
        auto offer = std::make_shared<Offer>(proxy);
        static const wl_data_offer_listener offer_listener = {
          +[](void* data, wl_data_offer*, const char* mime) {
            if (!strcmp(mime, kMime)) static_cast<Offer*>(data)->panel = true;
          },
          +[](void*, wl_data_offer*, uint32_t) {},
          +[](void*, wl_data_offer*, uint32_t) {},
        };
        wl_data_offer_add_listener(proxy, &offer_listener, offer.get());
        self->offers_.push_back(offer);
      },
      +[](void* data, wl_data_device*, uint32_t serial, wl_surface* surface, wl_fixed_t x, wl_fixed_t y, wl_data_offer* proxy) {
        auto* self = static_cast<Backend*>(data);
        self->target_ = nullptr;
        for (const auto& entry : self->entries_) {
          GtkWidget* top = gtk_widget_get_toplevel(GTK_WIDGET(entry->view));
          if (gtk_widget_get_mapped(GTK_WIDGET(entry->view)) &&
              gdk_wayland_window_get_wl_surface(gtk_widget_get_window(top)) == surface) {
            self->target_ = entry.get();
            break;
          }
        }
        self->offer_.reset();
        for (const auto& offer : self->offers_) if (offer->proxy == proxy) self->offer_ = offer;
        self->enter_serial_ = serial;
        self->x_ = wl_fixed_to_double(x);
        self->y_ = wl_fixed_to_double(y);
        self->Motion();
      },
      +[](void* data, wl_data_device*) {
        auto* self = static_cast<Backend*>(data);
        self->Notify("leave", false);
        self->target_ = nullptr;
        self->offer_.reset();
        self->offers_.clear();
      },
      +[](void* data, wl_data_device*, uint32_t, wl_fixed_t x, wl_fixed_t y) {
        auto* self = static_cast<Backend*>(data);
        self->x_ = wl_fixed_to_double(x);
        self->y_ = wl_fixed_to_double(y);
        self->Motion();
      },
      +[](void* data, wl_data_device*) { static_cast<Backend*>(data)->Notify("drop", true); },
      +[](void* data, wl_data_device*, wl_data_offer* proxy) {
        auto* self = static_cast<Backend*>(data);
        self->offers_.erase(std::remove_if(self->offers_.begin(), self->offers_.end(),
          [proxy](const std::shared_ptr<Offer>& offer) { return offer->proxy == proxy; }), self->offers_.end());
      },
    };
    wl_data_device_add_listener(device_, &device_listener, this);
  }

  void Motion() {
    if (!source_ || !offer_ || !offer_->panel || !target_) return;
    wl_data_offer_set_actions(offer_->proxy, WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE,
                              WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE);
    wl_data_offer_accept(offer_->proxy, enter_serial_, kMime);
    Notify("motion", false);
  }
  struct Reply { Backend* owner; std::shared_ptr<Offer> offer; };
  void Notify(const char* phase, bool drop) {
    if (!source_ || !target_ || !offer_ || !offer_->panel) return;
    int ox = 0, oy = 0;
    GtkWidget* view = GTK_WIDGET(target_->view);
    gtk_widget_translate_coordinates(view, gtk_widget_get_toplevel(view), 0, 0, &ox, &oy);
    g_autoptr(FlValue) arguments = fl_value_new_map();
    fl_value_set_string_take(arguments, "phase", fl_value_new_string(phase));
    fl_value_set_string(arguments, "payload", source_->payload);
    fl_value_set_string_take(arguments, "x", fl_value_new_float(x_ - ox));
    fl_value_set_string_take(arguments, "y", fl_value_new_float(y_ - oy));
    if (!drop) {
      fl_method_channel_invoke_method(target_->channel, "nativeTabDrag", arguments, nullptr, nullptr, nullptr);
      return;
    }
    offer_->dropped = true;
    fl_method_channel_invoke_method(target_->channel, "nativeTabDrag", arguments, nullptr,
      +[](GObject* object, GAsyncResult* result, gpointer data) {
        std::unique_ptr<Reply> reply(static_cast<Reply*>(data));
        g_autoptr(GError) error = nullptr;
        g_autoptr(FlMethodResponse) response = fl_method_channel_invoke_method_finish(
            FL_METHOD_CHANNEL(object), result, &error);
        FlValue* value = response ? fl_method_response_get_result(response, nullptr) : nullptr;
        if (reply->offer->proxy && value &&
            fl_value_get_type(value) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(value)) {
          wl_data_offer_finish(reply->offer->proxy);
        } else {
          // The receiver still owns references after a rejected drop. Destroy
          // the offer explicitly so it cannot leave the source awaiting finish.
          if (reply->offer->proxy) {
            wl_data_offer_destroy(reply->offer->proxy);
            reply->offer->proxy = nullptr;
          }
          reply->owner->Finish("cancelled");
        }
      }, new Reply{this, offer_});
  }

  void CreateIcon(FlValue* arguments, FlView* view) {
    if (!compositor_ || !shm_) return;
    g_autoptr(GdkPixbufLoader) loader = gdk_pixbuf_loader_new();
    FlValue* png = fl_value_lookup_string(arguments, "png");
    GdkPixbuf* pixbuf = nullptr;
    if (png && fl_value_get_type(png) == FL_VALUE_TYPE_UINT8_LIST) {
      g_autoptr(GError) error = nullptr;
      if (gdk_pixbuf_loader_write(loader, fl_value_get_uint8_list(png), fl_value_get_length(png), &error) &&
          gdk_pixbuf_loader_close(loader, &error))
        pixbuf = gdk_pixbuf_loader_get_pixbuf(loader);
    }
    const int scale = std::max(1, gtk_widget_get_scale_factor(GTK_WIDGET(view)));
    const int image_width = pixbuf ? gdk_pixbuf_get_width(pixbuf) : 1;
    const int image_height = pixbuf ? gdk_pixbuf_get_height(pixbuf) : 1;
    // Fractional app zoom can produce odd PNG extents on a 2x GTK display.
    // Wayland buffers must be divisible by their integer buffer scale.
    int width = ((image_width + scale - 1) / scale) * scale;
    int height = ((image_height + scale - 1) / scale) * scale;
    int stride = cairo_format_stride_for_width(CAIRO_FORMAT_ARGB32, width);
    source_->size = static_cast<size_t>(stride) * height;
    g_autofree gchar* path = nullptr;
    source_->fd = g_file_open_tmp("tal-drag-XXXXXX", &path, nullptr);
    if (source_->fd < 0) return;
    unlink(path);
    if (ftruncate(source_->fd, source_->size) != 0) return;
    source_->pixels = mmap(nullptr, source_->size, PROT_READ | PROT_WRITE, MAP_SHARED, source_->fd, 0);
    if (source_->pixels == MAP_FAILED) return;
    auto* surface = cairo_image_surface_create_for_data(static_cast<unsigned char*>(source_->pixels),
        CAIRO_FORMAT_ARGB32, width, height, stride);
    cairo_t* cr = cairo_create(surface);
    if (pixbuf) { gdk_cairo_set_source_pixbuf(cr, pixbuf, 0, 0); cairo_paint(cr); }
    cairo_destroy(cr);
    cairo_surface_flush(surface);
    source_->pool = wl_shm_create_pool(shm_, source_->fd, source_->size);
    source_->buffer = wl_shm_pool_create_buffer(source_->pool, 0, width, height, stride, WL_SHM_FORMAT_ARGB8888);
    static const wl_buffer_listener buffer_listener = {
      +[](void*, wl_buffer*) {},
    };
    wl_buffer_add_listener(source_->buffer, &buffer_listener, nullptr);
    source_->icon = wl_compositor_create_surface(compositor_);
    wl_surface_set_buffer_scale(source_->icon, scale);
    wl_surface_attach(source_->icon, source_->buffer, -40, -12);
    wl_surface_damage(source_->icon, 0, 0, width, height);
    wl_surface_commit(source_->icon);
    cairo_surface_destroy(surface);
  }
  void Stop() {
    stopping_ = true;
    if (pump_) { g_source_remove(pump_); pump_ = 0; }
    Finish("cancelled");
    offer_.reset();
    offers_.clear();
    target_ = nullptr;
    if (pointer_) { wl_pointer_destroy(pointer_); pointer_ = nullptr; }
    if (touch_) { wl_touch_destroy(touch_); touch_ = nullptr; }
    if (device_) { wl_data_device_destroy(device_); device_ = nullptr; }
    if (seat_) { wl_seat_destroy(seat_); seat_ = nullptr; }
    if (manager_) { wl_data_device_manager_destroy(manager_); manager_ = nullptr; }
    if (shm_) { wl_shm_destroy(shm_); shm_ = nullptr; }
    if (compositor_) { wl_compositor_destroy(compositor_); compositor_ = nullptr; }
    if (registry_) { wl_registry_destroy(registry_); registry_ = nullptr; }
    if (queue_) { wl_event_queue_destroy(queue_); queue_ = nullptr; }
  }
};

Backend* GetBackend(FlView* view) {
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(view));
  auto* backend = static_cast<Backend*>(g_object_get_data(G_OBJECT(display), kBackend));
  if (!backend) {
    backend = new Backend(display);
    g_object_set_data_full(G_OBJECT(display), kBackend, backend,
        +[](gpointer data) { delete static_cast<Backend*>(data); });
  }
  return backend;
}
}
void TalWaylandDragRegister(FlView* view, FlMethodChannel* channel) { GetBackend(view)->Register(view, channel); }
void TalWaylandDragUnregister(FlView* view) { GetBackend(view)->Unregister(view); }
void TalWaylandDragBegin(FlView* view, TalWindowInput* input, FlMethodCall* call) { GetBackend(view)->Begin(view, input, call); }
#else
void TalWaylandDragRegister(FlView*, FlMethodChannel*) {}
void TalWaylandDragUnregister(FlView*) {}
void TalWaylandDragBegin(FlView*, TalWindowInput*, FlMethodCall* call) {
  fl_method_call_respond_not_implemented(call, nullptr);
}
#endif

