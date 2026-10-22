#ifndef HARBORPROXY_PROXY_OWNERSHIP_TEST
#include "proxy_plugin.h"
#endif

// This must be included before many other Windows headers.
#include <windows.h>

#include <WinInet.h>
#include <algorithm>
#include <cstring>
#include <string>
#include <vector>

#pragma comment(lib, "wininet")
#pragma comment(lib, "Advapi32")

#ifdef HARBORPROXY_PROXY_OWNERSHIP_TEST
#include <flutter/encodable_value.h>
#else
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#endif

#include <memory>

namespace
{

constexpr int kMinProxyPort = 1;
constexpr int kMaxProxyPort = 65535;
constexpr wchar_t kInternetSettingsKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
#ifdef HARBORPROXY_PROXY_OWNERSHIP_TEST
constexpr wchar_t kOwnershipKey[] = L"Software\\HarborProxy\\ProxyOwnershipTest";
#else
constexpr wchar_t kOwnershipKey[] = L"Software\\HarborProxy\\SystemProxyOwnership";
#endif

std::wstring Utf8ToWide(const std::string& value)
{
  if (value.empty())
  {
    return {};
  }
  const int size = MultiByteToWideChar(
      CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0)
  {
    return std::wstring(value.begin(), value.end());
  }
  std::wstring result(size, L'\0');
  MultiByteToWideChar(
      CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
      result.data(), size);
  return result;
}

std::wstring BuildBypassList(const flutter::EncodableList& bypassDomain)
{
  std::wstring bypassList;
  for (const auto& domain : bypassDomain)
  {
    const auto& value = std::get<std::string>(domain);
    if (!bypassList.empty())
    {
      bypassList += L";";
    }
    bypassList += Utf8ToWide(value);
  }
  return bypassList;
}

bool IsStringList(const flutter::EncodableList& values)
{
  return std::all_of(
      values.begin(), values.end(), [](const auto& value)
      {
        return std::holds_alternative<std::string>(value);
      });
}

struct ProxyState {
  DWORD flags = 0;
  std::wstring server, bypass, pac;
  bool operator==(const ProxyState& other) const {
    return flags == other.flags && server == other.server &&
        bypass == other.bypass && pac == other.pac;
  }
};

bool ReadProxyState(ProxyState& state) {
  INTERNET_PER_CONN_OPTIONW options[4] = {};
  const DWORD names[] = {INTERNET_PER_CONN_FLAGS, INTERNET_PER_CONN_PROXY_SERVER,
      INTERNET_PER_CONN_PROXY_BYPASS, INTERNET_PER_CONN_AUTOCONFIG_URL};
  for (int i = 0; i < 4; ++i) options[i].dwOption = names[i];
  INTERNET_PER_CONN_OPTION_LISTW list = {};
  list.dwSize = sizeof(list);
  list.dwOptionCount = 4;
  list.pOptions = options;
  DWORD size = sizeof(list);
  const bool success = InternetQueryOptionW(nullptr,
      INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size) != FALSE;
  if (success) {
    state.flags = options[0].Value.dwValue;
    state.server = options[1].Value.pszValue ? options[1].Value.pszValue : L"";
    state.bypass = options[2].Value.pszValue ? options[2].Value.pszValue : L"";
    state.pac = options[3].Value.pszValue ? options[3].Value.pszValue : L"";
  }
  for (int i = 1; i < 4; ++i) if (options[i].Value.pszValue) GlobalFree(options[i].Value.pszValue);
  return success;
}

bool ApplyProxyState(ProxyState state) {
  INTERNET_PER_CONN_OPTIONW options[4] = {};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[0].Value.dwValue = state.flags;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[1].Value.pszValue = state.server.data();
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[2].Value.pszValue = state.bypass.data();
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  options[3].Value.pszValue = state.pac.data();
  INTERNET_PER_CONN_OPTION_LISTW list = {};
  list.dwSize = sizeof(list);
  list.dwOptionCount = 4;
  list.pOptions = options;
  // Scope is the default/LAN connection. Do not overwrite unrelated RAS/VPN entries.
  return InternetSetOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
      &list, sizeof(list)) != FALSE;
}

void AppendNumber(std::vector<BYTE>& data, DWORD value) {
  const auto* bytes = reinterpret_cast<const BYTE*>(&value);
  data.insert(data.end(), bytes, bytes + sizeof(value));
}
void AppendState(std::vector<BYTE>& data, const ProxyState& state) {
  AppendNumber(data, state.flags);
  for (const auto* value : {&state.server, &state.bypass, &state.pac}) {
    AppendNumber(data, static_cast<DWORD>(value->size()));
    const auto* bytes = reinterpret_cast<const BYTE*>(value->data());
    data.insert(data.end(), bytes, bytes + value->size() * sizeof(wchar_t));
  }
}
bool TakeNumber(const std::vector<BYTE>& data, size_t& offset, DWORD& value) {
  if (offset > data.size() || data.size() - offset < sizeof(value)) return false;
  std::memcpy(&value, data.data() + offset, sizeof(value));
  offset += sizeof(value);
  return true;
}
bool TakeState(const std::vector<BYTE>& data, size_t& offset, ProxyState& state) {
  if (!TakeNumber(data, offset, state.flags)) return false;
  for (auto* value : {&state.server, &state.bypass, &state.pac}) {
    DWORD length = 0;
    if (!TakeNumber(data, offset, length) || length > 16384 ||
        data.size() - offset < length * sizeof(wchar_t)) return false;
    value->resize(length);
    std::memcpy(value->data(), data.data() + offset, length * sizeof(wchar_t));
    offset += length * sizeof(wchar_t);
  }
  return true;
}
bool SaveOwnership(const ProxyState& original, const ProxyState& applied) {
  std::vector<BYTE> data;
  AppendNumber(data, 1);
  AppendState(data, original);
  AppendState(data, applied);
  if (data.size() > 65536) return false;
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kOwnershipKey, 0, nullptr,
      REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) return false;
  const bool success = RegSetValueExW(key, L"Journal", 0, REG_BINARY,
      data.data(), static_cast<DWORD>(data.size())) == ERROR_SUCCESS &&
      RegFlushKey(key) == ERROR_SUCCESS;
  RegCloseKey(key);
  return success;
}
bool ReadOwnership(ProxyState& original, ProxyState& applied, bool& exists) {
  exists = false;
  HKEY key = nullptr;
  const auto opened = RegOpenKeyExW(HKEY_CURRENT_USER, kOwnershipKey, 0, KEY_QUERY_VALUE, &key);
  if (opened == ERROR_FILE_NOT_FOUND) return true;
  if (opened != ERROR_SUCCESS) return false;
  DWORD type = 0, size = 0;
  auto result = RegQueryValueExW(key, L"Journal", nullptr, &type, nullptr, &size);
  if (result == ERROR_FILE_NOT_FOUND) { RegCloseKey(key); return true; }
  if (result != ERROR_SUCCESS || type != REG_BINARY || size > 65536) { RegCloseKey(key); return false; }
  std::vector<BYTE> data(size);
  result = RegQueryValueExW(key, L"Journal", nullptr, &type, data.data(), &size);
  RegCloseKey(key);
  size_t offset = 0;
  DWORD version = 0;
  if (result != ERROR_SUCCESS || !TakeNumber(data, offset, version) || version != 1 ||
      !TakeState(data, offset, original) || !TakeState(data, offset, applied) || offset != data.size()) return false;
  exists = true;
  return true;
}
bool ClearOwnership() {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kOwnershipKey, 0, KEY_SET_VALUE, &key) != ERROR_SUCCESS) return false;
  const auto result = RegDeleteValueW(key, L"Journal");
  const bool success = (result == ERROR_SUCCESS || result == ERROR_FILE_NOT_FOUND) && RegFlushKey(key) == ERROR_SUCCESS;
  RegCloseKey(key);
  return success;
}

bool NotifySettingsChanged()
{
  const bool changed = InternetSetOption(
      nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0) != FALSE;
  const bool refreshed = InternetSetOption(
      nullptr, INTERNET_OPTION_REFRESH, nullptr, 0) != FALSE;
  DWORD_PTR ignored = 0;
  SendMessageTimeoutW(
      HWND_BROADCAST, WM_SETTINGCHANGE, 0,
      reinterpret_cast<LPARAM>(kInternetSettingsKey),
       SMTO_ABORTIFHUNG, 2000, &ignored);
  return changed && refreshed;
}

bool stopProxy()
{
  ProxyState original, applied, current;
  bool exists = false;
  if (!ReadOwnership(original, applied, exists)) return false;
  if (!exists) return true;  // Startup must not clear a proxy owned by somebody else.
  if (!ReadProxyState(current)) return false;
  ProxyState restored = current;
  if (current.server == applied.server) {
    restored.server = original.server;
    if (current.bypass == applied.bypass) restored.bypass = original.bypass;
    if (current.flags == applied.flags && current.pac == applied.pac) restored.flags = original.flags;
  }
  if (!(restored == current) && (!ApplyProxyState(restored) || !NotifySettingsChanged())) return false;
  ProxyState verified;
  if (!ReadProxyState(verified) || !(verified == restored)) return false;
  return ClearOwnership();
}

bool startProxy(const int port, const flutter::EncodableList& bypassDomain) {
  if (!stopProxy()) return false;
  ProxyState original;
  if (!ReadProxyState(original)) return false;
  ProxyState applied = original;
  applied.flags = PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY;
  applied.server = Utf8ToWide("127.0.0.1:" + std::to_string(port));
  applied.bypass = BuildBypassList(bypassDomain);
  if (!SaveOwnership(original, applied)) return false;
  ProxyState verified;
  if (!ApplyProxyState(applied) || !NotifySettingsChanged() ||
      !ReadProxyState(verified) || !(verified == applied)) {
    stopProxy();
    return false;
  }
  return true;
}

}  // namespace

#ifndef HARBORPROXY_PROXY_OWNERSHIP_TEST
namespace proxy
{

  // static
  void ProxyPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarWindows *registrar)
  {
    auto channel =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), "proxy",
            &flutter::StandardMethodCodec::GetInstance());

    auto plugin = std::make_unique<ProxyPlugin>();

    channel->SetMethodCallHandler(
        [plugin_pointer = plugin.get()](const auto &call, auto result)
        {
          plugin_pointer->HandleMethodCall(call, std::move(result));
        });

    registrar->AddPlugin(std::move(plugin));
  }

  void ProxyPlugin::HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    if (method_call.method_name() == "StopProxy")
    {
      result->Success(stopProxy());
    }
    else if (method_call.method_name() == "StartProxy")
    {
      auto *arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
      if (arguments == nullptr)
      {
        result->Error("bad_args", "StartProxy requires argument map");
        return;
      }
      auto portIt = arguments->find(flutter::EncodableValue("port"));
      auto bypassDomainIt = arguments->find(flutter::EncodableValue("bypassDomain"));
      if (portIt == arguments->end() || bypassDomainIt == arguments->end())
      {
        result->Error("bad_args", "StartProxy requires port and bypassDomain");
        return;
      }
      auto *port = std::get_if<int>(&portIt->second);
      auto *bypassDomain = std::get_if<flutter::EncodableList>(&bypassDomainIt->second);
      if (port == nullptr || bypassDomain == nullptr)
      {
        result->Error("bad_args", "StartProxy argument types are invalid");
        return;
      }
      if (*port < kMinProxyPort || *port > kMaxProxyPort)
      {
        result->Error("bad_args", "StartProxy port must be between 1 and 65535");
        return;
      }
      if (!IsStringList(*bypassDomain))
      {
        result->Error(
            "bad_args", "StartProxy bypassDomain must contain only strings");
        return;
      }
      result->Success(startProxy(*port, *bypassDomain));
    }
    else
    {
      result->NotImplemented();
    }
  }
} // namespace proxy
#endif
