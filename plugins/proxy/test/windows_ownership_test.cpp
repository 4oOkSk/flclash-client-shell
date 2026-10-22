// Run on an idle Windows test account. Always restores its WinINet snapshot.
#define HARBORPROXY_PROXY_OWNERSHIP_TEST
#include "../windows/proxy_plugin.cpp"
#include <iostream>
#include <stdexcept>

void Require(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}

int main() {
  ProxyState baseline;
  if (!ReadProxyState(baseline)) return 2;
  for (const auto* keyName : {kOwnershipKey, L"Software\\HarborProxy\\SystemProxyOwnership"}) {
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, keyName, 0, KEY_QUERY_VALUE, &key) == ERROR_SUCCESS) {
      DWORD size = 0;
      const auto result = RegQueryValueExW(key, L"Journal", nullptr, nullptr, nullptr, &size);
      RegCloseKey(key);
      if (result != ERROR_FILE_NOT_FOUND) return 3;
    }
  }
  bool passed = false;
  try {
    ProxyState corporate = baseline;
    corporate.flags = PROXY_TYPE_DIRECT | PROXY_TYPE_AUTO_PROXY_URL;
    corporate.server = L"127.0.0.1:8080";
    corporate.bypass = L"corporate.local";
    corporate.pac = L"http://127.0.0.1:9/ownership-test.pac";
    Require(ApplyProxyState(corporate) && NotifySettingsChanged(), "fixture apply failed");
    ProxyState actual;
    Require(ReadProxyState(actual) && actual == corporate, "fixture readback failed");
    Require(stopProxy(), "unowned stop failed");
    Require(ReadProxyState(actual) && actual == corporate, "unowned proxy was changed");
    flutter::EncodableList bypass{flutter::EncodableValue("localhost")};
    Require(startProxy(7890, bypass), "owned start failed");
    Require(stopProxy(), "owned stop failed");
    Require(ReadProxyState(actual) && actual == corporate, "original settings not restored");
    Require(startProxy(7890, bypass), "second start failed");
    Require(ReadProxyState(actual), "owned readback failed");
    actual.server = L"127.0.0.1:9999";
    Require(ApplyProxyState(actual) && NotifySettingsChanged(), "external change failed");
    Require(stopProxy(), "external stop failed");
    ProxyState preserved;
    Require(ReadProxyState(preserved) && preserved == actual, "external settings were overwritten");
    std::vector<BYTE> data;
    AppendState(data, corporate);
    size_t offset = 0;
    ProxyState decoded;
    Require(TakeState(data, offset, decoded) && decoded == corporate && offset == data.size(), "journal round trip failed");
    data.pop_back(); offset = 0;
    Require(!TakeState(data, offset, decoded), "truncated journal accepted");
    passed = true;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
  }
  const bool restored = ApplyProxyState(baseline) && NotifySettingsChanged();
  ProxyState verified;
  const bool verifiedRestore = restored && ReadProxyState(verified) && verified == baseline;
  // This test key never refers to another application/session's journal.
  RegDeleteTreeW(HKEY_CURRENT_USER, kOwnershipKey);
  std::cout << "windows_proxy_ownership=" << (passed ? "passed" : "failed")
            << " baseline_restored=" << (verifiedRestore ? "true" : "false") << '\n';
  return passed && verifiedRestore ? 0 : 1;
}
