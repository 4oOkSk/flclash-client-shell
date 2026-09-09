# Managed client interface and routing

The managed client uses Home, Routes, Routing and Account as its four primary destinations.
Requests, connections and resources remain available under Account → Diagnostics. Advanced
settings and routing editors remain available; generic builds retain the upstream dashboard.
The classic Material theme follows the website's blue app bars, white surfaces, grey background
and small corners, with a corresponding dark palette. Native lifecycle ownership is unchanged.

## Exceptions

The simple editor accepts a domain, HTTP(S) URL or literal IP address. A URL is normalized to its
hostname; paths and query strings do not become routing criteria. Domain suffix matching is
explicit. Actions are the managed current-line group, DIRECT and REJECT. Network ranges,
custom groups, additional flags, rule sets and scripts remain in the advanced editor so editing
a simple rule cannot silently discard advanced behavior. Existing rule ordering is preserved;
the first matching exception precedes the managed default policy.

Rules are saved to the existing database and applied through the existing serialized setup
owner. The routing page distinguishes applying, applied, restored and failed. Invalid local
rules or scripts do not cause a retry with an empty default overlay: the last successfully
applied complete overlay is retried instead. Without a valid recovery overlay the operation
fails closed. Authentication and transport errors are not masked as routing errors.

The recovery overlay is stored in the existing preferences as `private_client_applied_route`.
It contains only user routing rules, rule-provider settings and the managed routing mode; it
does not contain server endpoints, credentials or the full server configuration. A recovery
storage failure is displayed separately from successful application to the core.

Mode and exception changes affect new connections. Existing traffic is not closed implicitly.
The explicit reconnect action warns about interruption and requires confirmation.

## Routing preview

`client-route-preview` uses the currently applied core rules for a hypothetical HTTPS/TCP
connection. It never performs a DNS lookup or a network connectivity probe. The response
contains a result category, direct/proxy/reject action and rule index/type, never a server or
proxy-chain definition. If an earlier rule requires an IP address, process information or
unsupported context, the result is indeterminate rather than a guessed match.

## Acceptance

Changes to the rule editor require domain/URL/IP normalization and advanced-rule preservation
checks. Changes to application feedback require invalid input, recovery and authentication
error checks. Device acceptance must exercise the released candidate on Windows, Linux and
the Android emulator; cold-start smoke alone does not prove proxy/TUN or rule effectiveness.
macOS remains a build-only result when no device is available.
