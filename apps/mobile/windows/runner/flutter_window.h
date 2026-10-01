#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Board 49: started by Windows at sign-in, Skyline stays by the clock and
  // the window is not shown.
  void SetStartHidden(bool hidden) { start_hidden_ = hidden; }

  // Posted when a second launch hands over to this one: show the window.
  static constexpr UINT kShowMessage = WM_APP + 0x51;

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  bool start_hidden_ = false;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // "skyline/screen": keeps view-once media out of screenshots and capture.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> screen_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
