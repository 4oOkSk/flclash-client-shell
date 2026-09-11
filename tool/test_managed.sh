#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export EXPECT_MANAGED_TESTS=1
exec flutter test --reporter expanded \
  --dart-define=PRIVATE_CLIENT_ENROLL_BLOB=managed-test-only \
  test/managed_mode_test.dart \
  test/providers/private_client_selected_map_test.dart \
  test/widgets/diagnostic_export_test.dart \
  test/widgets/private_connection_details_test.dart \
  test/widgets/private_routing_layout_test.dart
