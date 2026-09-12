# Managed client interface and routing

The managed client uses Home, Servers, Rules and Account as its four primary destinations.
Requests, connections and resources remain available under Account → Diagnostics. Advanced
settings and routing editors remain available; generic builds retain the upstream dashboard.
The classic Material theme uses neutral window chrome and navigation, white cards, a light grey
background and small corners. Blue highlights selection and actions, with a corresponding dark
palette. Native lifecycle ownership is unchanged.

Managed cards share one surface, four-pixel corners, a neutral outline and no drop shadow.
Information-only cards are not buttons and do not acquire a selection border on hover.
Blue card outlines identify an actual selected option, not a passive account summary.
Settings, diagnostics and advanced options use the same inset card groups and row typography;
dividers stay inside their groups rather than spanning the page canvas.

Account → Diagnostics always includes **Copy diagnostic report**, including when no other
diagnostic destinations are available. It uses the existing redacted report and clipboard path,
blocks duplicate requests while collecting, and reports copy success or failure. Navigating away
during collection must not update disposed widget state. The managed Home has no diagnostic
export toolbar; generic dashboard behavior is unchanged.

Clipboard reports use format 2 and are bounded to 8192 UTF-8 bytes, independently of a device's
clipboard limit. Status, errors/warnings, compact route samples and platform evidence precede
secondary metadata and routine context. Repeated redacted messages keep a count and first/last
timestamps; group refreshes, HTTP lookups, lifecycle events and GeoSite loads become counters.
Failures are selected before recent routine messages, with redacted reason text and fixed signal
labels (such as DNS/TLS/timeout) rather than only a destination. Failed/rejected samples precede other connections;
the report remains a sample of retained events, not a complete packet trace. Coverage records
included/omitted groups and rows; an ellipsis marks shortened fields. Destination validation and
credential/server redaction remain in place. Collection failures are explicit, Android reports
include access-control counts (not app lists), and probes identify their core-outbound scope;
probe success does not establish browser, certificate or VPN/TUN-path correctness.

DNS service counters cover completed VPN/listener queries across the core-process lifetime,
including silent SERVFAIL and timeout results; an absent counter is unavailable, not zero.
Log-derived counts still describe retained logs only. Android socket protection propagates its
Boolean result across Kotlin/JNI/C/Go: a failure blocks the socket, increments a lifetime counter
and emits one bounded warning. It must never silently continue with an unprotected socket.
Android disconnect acknowledges native teardown rather than merely queued intent. TUN shutdown
drains existing JNI callbacks, detaches their state under the callback gate, then releases the
gate before closing the listener. Teardown callbacks cannot deadlock behind their own close;
the socket hook keeps rejecting new sockets until listener closure completes.
Configured server/IP/SNI plus port matches use `[server-endpoint]` without the real port in
lists, connection/request details and clipboard samples. The inbound category and routing result
remain visible. Such a match is a possible reentry signal, not proof of a loop, and ordinary
visits to another port are not classified as node traffic. A passive observer of existing proxy
DNS lookups adds resolved addresses to the diagnostic index without issuing DNS requests or
changing lookup results. Core log events are filtered before both console output and delivery
to the UI; known node hosts and their ports are hidden even outside the traffic destination field.
Unclassified app URL logs use strict redaction; ordinary visited destinations remain available
from connection metadata. This presentation protection does not hide the actual network peer
from the operating system or change configuration delivery, secure storage or file sharing.

Managed destination resolution uses certificate-verified DoH over TCP/443 at literal resolver
IPs, avoiding both a hard TCP/53 dependency on the selected server and recursive resolver-name
bootstrap. Mainland and overseas DNS continue to follow the selected split policy through
`respect-rules`; no forced-DIRECT destination fallback is introduced. The separate direct
proxy-server bootstrap resolvers remain unchanged and do not resolve ordinary visited sites.
Changing managed servers closes DNS transport pools before the connection-teardown response,
including both default and policy-specific resolvers. Applying a different routing mode creates
fresh resolvers, so reusable DoH connections cannot keep the previous mode's outbound path.

## Shared routing policy

`core/routing_policy.json` is the shared category/resolver source. The website consumes its
byte-identical `resources/conf/routing_policy.json` mirror through `HappRouting.php`.
After changing the source, run `python3 tool/sync_routing_policy.py --website-root <website>`;
use `--check` before releasing either consumer. Schema and priority changes must be supported
explicitly by both adapters; this is not a general rule language.

For ordinary public destinations, the common policy is:

| Category | Bypass mainland China | Proxy mainland China | Proxy all traffic |
| --- | --- | --- | --- |
| Google, YouTube, Google Play, including overlaps with China lists | Proxy | Direct | Proxy |
| Complete `geosite:cn` and known mainland destination IPs | Direct | Proxy | Proxy |
| Additional Apple/Microsoft/games China categories | Default unless also CN | Proxy | Proxy |
| Other public destinations | Proxy | Direct | Proxy |
| Private names and private destination IPs | Direct | Direct | Direct |

Google's priority also applies to destination DNS: its queries use Cloudflare DoH before
the China and return-category AliDNS policies. Both resolver endpoints follow the traffic
mode. The return mode deliberately supersedes the September 1 Google-China-first overlap
policy; it does not remove Apple/Microsoft/games return coverage or narrow `geosite:cn`.
The checked-in historical tests cover Play API/CDN hosts, reCAPTCHA, WeChat, Xiaohongshu,
Windows Update and China game CDN names using the bundled geodata and actual Core parser.
These deterministic routing tests do not assert account-level app-store downloads.

HarborProxy keeps local user rules ahead of defaults. Private traffic bypasses its split-mode
public UDP/443 compatibility guard; this does not enable unsupported node UDP or alter
Android socket protection. Global mode needs no public category rules with identical targets,
so it no longer performs a redundant China-IP resolution before the final proxy match.
Legacy serialized modes, advanced providers/scripts, split-only sniffing, IPv6 ownership,
and last-successful-overlay recovery are unchanged.

Happ's regular routing-link format groups entire direct/proxy lists rather than arbitrary
ordered rules. Return mode uses direct-before-proxy for Google overlap priority; outbound
uses proxy-before-direct. `AsIs` avoids a new lookup solely to select an IP rule. Do not
silently replace regular subscriptions with full Xray JSON to hide representational limits.
The native clients still differ for QUIC guards, IPv6 and simultaneous domain/private-IP
metadata. Happ exposes only one proxy-side resolver in global mode; HarborProxy retains its
historical China/overseas DNS split with both paths proxied. Shared category intent does
not imply byte-identical DNS engines or identical results with different cached geodata.
Happ does not expose an independent DNS fallback policy for unclassified names. Do not
promise that a final direct route also makes an unclassified DNS query direct; HarborProxy
uses its default Cloudflare policy for those names. Happ's native behavior needs separate
path evidence. The optional HarborProxy IPv6 rejection still precedes mainland DNS IPv6
prefixes; private IPv6 remains excepted, and the built-in DoH endpoints use IPv4.

## Shared application layout

The managed Windows and Linux window controls share one quiet, full-width 48-pixel title bar.
The four primary destinations omit duplicate page headings and their empty toolbar rows on
desktop and mobile; navigation identifies the current page. Their content shares a maximum
width of 1040 logical pixels and a consistent alignment. Secondary routes retain their own title
and back navigation, and action/search toolbars are not hidden. Native macOS title-bar behavior
is unchanged. Mobile content retains system safe-area padding.

Account diagnostics, account advanced settings, and advanced routing use separate, stable
page-storage keys from their containing lists. Expansion state must never share the scroll
offset slot. Returning to or recreating these pages preserves expansion and scroll position
independently; keys do not depend on translated titles.
The checker's text scrolling has its own storage scope, separate from page scrolling.

Wide windows use an expanded navigation rail with visible text. Medium windows keep labels
below the icons, and compact layouts use labeled bottom navigation. The managed layout does
not hide destination names through the generic client's label preference. The title bar, rail,
bottom navigation and page canvas share a neutral background. Primary buttons and navigation
selection use one blue palette and consistent corner treatment.

The design follows Material's [large-screen layout and navigation](https://m2.material.io/components/navigation-drawer)
and [navigation rail guidance](https://m2.material.io/components/navigation-rail), preserving
the website's classic Material styling rather than combining unrelated window and page themes.

Visual acceptance covers the affected window and interactions, not only isolated content widgets.
Whole-shell redesigns cover all four primary pages, desktop/mobile layouts and dark mode; local edits
check affected views. Component screenshots with demonstration data do not prove native behavior.

Routing presents the three modes side by side when width and text scale permit. Exceptions
remain the primary task, with the rule checker alongside them on wide layouts and below them
on compact layouts. Application status stays visible without a separate large card; manual
application remains available, and reconnect is under its overflow menu with the existing
confirmation. Failed application and unsaved recovery state retain explicit warning feedback.

## Exceptions

English UI copy distinguishes a selected **server** from traffic **rules**. The three traffic
modes are **Bypass mainland China**, **Proxy mainland China**, and **Proxy all traffic**;
their descriptions spell out direct access, the return-to-China server, and required system
exceptions. This wording does not rename configuration keys, change server selection, or alter
the core's routing policy. The simple editor uses **Custom rules** and **Check rule match**;
the checker remains a prediction, not a live connectivity test.

Account overview, remaining data, expiry, account errors, website links, and sign-in/retry
prompts use the same ARB localization path as the rest of the interface. These labels must
follow language changes rather than contain hardcoded Chinese or reuse unrelated action names.

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

Logical AND/OR/NOT rules use bounded three-valued evaluation: a known false AND branch or
true OR branch can resolve a rule even when another branch needs context. In particular, the
managed UDP/443 guard cannot match the checker's TCP input. Unknown branches are never guessed;
no DNS lookup is added. Editing the destination or changing rules/application state invalidates
both displayed results and in-flight replies. Applied rules do not show a redundant save button;
manual reapplication remains in the overflow menu and unsuccessful application offers Retry.

## Connection feedback and servers

Home distinguishes the proxy's lifecycle state from an observational server check, without
claiming that TUN/VPN is active on a system-proxy-only desktop. A disconnected
underlying network is shown explicitly; otherwise a bounded HTTPS check through the selected
core outbound reports checking, reachable or unavailable. This is not a browser/TUN end-to-end
test and never claims every site is reachable. Network changes and successful server switches
invalidate old results; foreground checks are debounced and repeated at most once a minute,
and background/stop cancels scheduled checks. The observer never starts, stops or switches the
core. Existing automatic groups retain the core's health checking, failure threshold and latency
tolerance; manual selection is never silently replaced by a second Flutter failover algorithm.

Server changes are serialized. A missing RPC reply is unconfirmed, not an empty success;
current core selection is read back before committing a lost-ACK result. Failed storage writes
attempt to restore the previous actual selection; failed rollback reports the observed selection
and an unsaved/unconfirmed outcome. Diagnostic reports include the latest attempt/outcome,
health scope/time and desired/applied routing state. No endpoint or connection parameters are
added to these fields.

Servers share inset card rows, searchable display names, four-at-a-time HTTPS checks and an
optional available-first ordering. Results show the local check time and do not imply download
speed or unrestricted reachability. Automatic entries show the current leaf server. Names that
differ only in whitespace receive stable display suffixes; raw identities are never trimmed or
rewritten for core calls or storage. Check buttons retain a 48-pixel touch target.

System text scaling, including nonlinear accessibility scaling, is preserved unless the user
explicitly enables an application font-size override. Managed Home no longer performs hidden
seven-site IP lookups. Generic IP detection uses one HTTPS source with one sequential fallback,
validates the parsed IP, cancels each completed/timed-out request and has an eight-second maximum
request budget. There is no cross-server IP cache that could report a previous outbound address.

Application HTTP uses the platform's normal certificate verification; the previous global
accept-any-certificate callback is removed. This does not change the separately certificate-
verified Go login/config or destination DoH transports, and does not change DNS split policies.

## Acceptance

Changes to the rule editor require domain/URL/IP normalization and advanced-rule preservation
checks. Changes to application feedback require invalid input, recovery and authentication
error checks. Select device acceptance by affected platform/behavior or explicit task requirements,
using the exact candidate build. Publication alone does not add a three-platform device suite;
cold-start smoke alone does not prove proxy/TUN or rule effectiveness.
macOS remains a build-only result when no device is available.
