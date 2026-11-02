# Linux 原生 Wayland

启动器在存在 `WAYLAND_DISPLAY` 时优先选择原生 Wayland，并允许 GDK 回退到 X11。
显式 `GDK_BACKEND=wayland` 或 `GDK_BACKEND=x11` 优先于自动选择。
程序按实际 GDK 显示后端选择交互方式，因此在 Wayland 桌面运行的 XWayland 实例仍使用 X11 路径。

## 窗口与拖放

- 主窗口和分离窗口都安装 GTK 焦点恢复处理，覆盖激活、重显和内容区点击。
- 焦点恢复只选择当前已激活窗口内部的 Flutter 视图，不激活后台窗口，也不抢占原生文件对话框。
- 原生 Wayland 使用系统拖放协议，由合成器移动拖动图像；图像包含当前拖动的标签和面板内容。
- 拖放保存真实鼠标／触摸按下事件的 Wayland 序号，避免 GTK 3 在未聚焦窗口上改用后来的键盘焦点事件序号。
- 每个目标窗口用自身坐标判定标签插入、面板组合及侧栏／底部停靠，不交换虚构的屏幕绝对坐标。
- 保留面板合并／停靠预览的停留时间；Escape 取消与拖出窗口拆分分别处理。
- 拖动时，将标签放到窗口顶部的“弹出为独立窗口”落点可创建独立窗口；同样可拆分组合分离窗口中的面板。
- Esc 或合成器取消拖动时保留原布局。GTK 3 在部分 Wayland 合成器上不能区分取消与无目标释放，因此不把通用拖放错误当作自动拆分指令；也可使用原有标签菜单弹出面板。
- 原生窗口放置交给合成器。程序不承诺将新窗口放在鼠标的屏幕绝对位置。
- 外部 ELF、CSV 和源码文件拖入继续使用原有文件拖放目标；面板拖动完成或取消后恢复这些目标。
- X11 的独立拖动预览窗口显式禁止接受焦点，恢复为普通窗口时恢复可编辑状态。

## 验证

框架回归测试：

```bash
flutter test test/native_panel_drag_test.dart test/native_panel_transfer_test.dart \
  test/keyboard_shortcuts_test.dart test/detached_panel_test.dart \
  test/detached_window_coordinator_test.dart test/workspace_interaction_test.dart
```

GTK 原生焦点测试（需要 GTK 3 开发库、Clang、Xvfb 和 Openbox）：

```bash
bash tool/test_linux_window_input.sh
python3 -m unittest discover -s tool/tests -p test_linux_launcher.py
```

GTK 测试覆盖已被 Flutter 消费的点击、窗口激活、隐藏重显、预览不可聚焦，以及原生模态对话框保持焦点。
框架测试覆盖 UI 缩放后的目标命中、拖放离开／释放顺序、重排、取消、跨窗口路由及缺少全局位置时保留尺寸。

Linux 构建、合成器运行与键盘测试的实际结果应与自动测试分别记录；这些测试不能代替物理 USB 探针、真实烧录或触摸屏验证。

需要原生焦点／拖放诊断日志时，可使用 `TAL_WAYLAND_DRAG_DEBUG=1 take-a-look`。
日志记录窗口焦点恢复、目标注册、拖动阶段和输入事件序号，不记录输入框文本。

## 依据

- [GTK 的窗口位置在 Wayland 下不可用](https://docs.gtk.org/gtk3/method.Window.get_position.html)
- [GTK 使用真实输入事件启动拖放](https://docs.gtk.org/gtk3/method.Widget.drag_begin_with_coordinates.html)
- [GTK 目标窗口拖放事件](https://docs.gtk.org/gtk3/signal.Widget.drag-motion.html)
