#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>
#include <cwctype>
#include <functional>
#include <iterator>
#include <string>
#include <thread>

#include "flutter_window.h"
#include "utils.h"

namespace {

// A name private to this copy of skyline.exe (by its path), so the installed
// app and a development build never mistake each other for themselves.
std::wstring InstanceName(const wchar_t* kind) {
  wchar_t path[MAX_PATH * 2] = {};
  ::GetModuleFileNameW(nullptr, path, static_cast<DWORD>(std::size(path)));
  std::wstring p(path);
  std::transform(p.begin(), p.end(), p.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  return L"Local\\Skyline-" + std::wstring(kind) + L"-" + std::to_wstring(std::hash<std::wstring>{}(p));
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // One Skyline at a time (board 49): two copies would open the same vault.
  // A second launch asks the running one to show its window, then leaves.
  HANDLE instance_mutex = ::CreateMutexW(nullptr, TRUE, InstanceName(L"instance").c_str());
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HANDLE show = ::OpenEventW(EVENT_MODIFY_STATE, FALSE, InstanceName(L"show").c_str());
    if (show != nullptr) {
      ::AllowSetForegroundWindow(ASFW_ANY);
      ::SetEvent(show);
      ::CloseHandle(show);
    }
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }
  HANDLE show_event = ::CreateEventW(nullptr, FALSE, FALSE, InstanceName(L"show").c_str());

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Started by Windows at sign-in (the Run key adds --background).
  window.SetStartHidden(command_line != nullptr && std::wstring(command_line).find(L"--background") != std::wstring::npos);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Skyline", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  if (show_event != nullptr) {
    HWND hwnd = window.GetHandle();
    std::thread([show_event, hwnd]() {
      while (::WaitForSingleObject(show_event, INFINITE) == WAIT_OBJECT_0) {
        if (!::PostMessageW(hwnd, FlutterWindow::kShowMessage, 0, 0)) break;
      }
    }).detach();
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
