#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <optional>
#include <ShlObj_core.h>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1,
                                         nullptr, 0);
  if (length <= 1) return {};
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, result.data(), length);
  result.pop_back();
  return result;
}

bool CopyFileToClipboard(const std::string& path_utf8) {
  const std::wstring path = Utf8ToWide(path_utf8);
  if (path.empty() || GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return false;
  }

  const SIZE_T bytes = sizeof(DROPFILES) +
                       (path.length() + 2) * sizeof(wchar_t);
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes);
  if (memory == nullptr) return false;

  auto* drop_files = static_cast<DROPFILES*>(GlobalLock(memory));
  if (drop_files == nullptr) {
    GlobalFree(memory);
    return false;
  }
  drop_files->pFiles = sizeof(DROPFILES);
  drop_files->fWide = TRUE;
  auto* files = reinterpret_cast<wchar_t*>(
      reinterpret_cast<BYTE*>(drop_files) + sizeof(DROPFILES));
  std::copy(path.begin(), path.end(), files);
  files[path.length()] = L'\0';
  files[path.length() + 1] = L'\0';
  GlobalUnlock(memory);

  if (!OpenClipboard(nullptr)) {
    GlobalFree(memory);
    return false;
  }
  EmptyClipboard();
  if (SetClipboardData(CF_HDROP, memory) == nullptr) {
    CloseClipboard();
    GlobalFree(memory);
    return false;
  }
  CloseClipboard();
  return true;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  native_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "bitshare/windows",
          &flutter::StandardMethodCodec::GetInstance());
  native_channel_->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() != "copyFile") {
          result->NotImplemented();
          return;
        }
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_arguments", "No se recibió un archivo.");
          return;
        }
        const auto path_it = arguments->find(flutter::EncodableValue("path"));
        if (path_it == arguments->end()) {
          result->Error("invalid_arguments", "No se recibió un archivo.");
          return;
        }
        const auto* path = std::get_if<std::string>(&path_it->second);
        if (path == nullptr || !CopyFileToClipboard(*path)) {
          result->Error("copy_failed", "No se pudo copiar el archivo.");
          return;
        }
        result->Success(flutter::EncodableValue(true));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  native_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
