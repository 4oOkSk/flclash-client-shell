bool requiresPrivilegedTunCoreAuthorization({
  required bool isAndroid,
  required bool requestedTun,
  required bool effectiveTun,
}) {
  if (isAndroid) return false;
  return requestedTun != effectiveTun && !effectiveTun;
}
