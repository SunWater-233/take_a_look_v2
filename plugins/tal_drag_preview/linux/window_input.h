#ifndef TAL_WINDOW_INPUT_H_
#define TAL_WINDOW_INPUT_H_

#include <gtk/gtk.h>

// Installed once for every FlView, including engines created by multi_window.
// The owner must outlive its view and call Dispose before releasing it.
class TalWindowInput {
 public:
  explicit TalWindowInput(GtkWidget* view);
  ~TalWindowInput();
  void SetPreview(bool preview);
  void RestoreFocus();
  GdkEvent* CopyPointerEvent() const;
  void EndPointerSequence(GdkEvent* press);

 private:
  static gboolean PointerEvent(GSignalInvocationHint*, guint, const GValue*,
                               gpointer);
  GtkWidget* view_;
  GtkWindow* window_;
  GdkEvent* pointer_event_ = nullptr;
  GtkWidget* pointer_widget_ = nullptr;
  gulong pointer_hook_ = 0;
  gulong touch_hook_ = 0;
  gulong focus_handler_ = 0;
  gulong map_handler_ = 0;
  gulong active_handler_ = 0;
  bool preview_ = false;
};

#endif
