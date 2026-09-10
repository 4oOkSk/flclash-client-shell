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

## Shared application layout

The managed Windows and Linux window controls share one quiet, full-width 48-pixel title bar.
The four primary destinations omit duplicate page headings and their empty toolbar rows on
desktop and mobile; navigation identifies the current page. Their content shares a maximum
width of 1040 logical pixels and a consistent alignment. Secondary routes retain their own title
and back navigation, and action/search toolbars are not hidden. Native macOS title-bar behavior
is unchanged. Mobile content retains system safe-area padding.

Wide windows use an expanded navigation rail with visible text. Medium windows keep labels
below the icons, and compact layouts use labeled bottom navigation. The managed layout does
not hide destination names through the generic client's label preference. The title bar, rail,
bottom navigation and page canvas share a neutral background. Primary buttons and navigation
selection use one blue palette and consistent corner treatment.

The design follows Material's [large-screen layout and navigation](https://m2.material.io/components/navigation-drawer)
and [navigation rail guidance](https://m2.material.io/components/navigation-rail), preserving
the website's classic Material styling rather than combining unrelated window and page themes.

Visual acceptance includes the entire window, not isolated content widgets: all four primary
pages, wide and medium desktop layouts, compact/mobile navigation, and dark mode. Component
screenshots with demonstration data are not substitutes for native package acceptance.

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

## Acceptance

Changes to the rule editor require domain/URL/IP normalization and advanced-rule preservation
checks. Changes to application feedback require invalid input, recovery and authentication
error checks. Device acceptance must exercise the released candidate on Windows, Linux and
the Android emulator; cold-start smoke alone does not prove proxy/TUN or rule effectiveness.
macOS remains a build-only result when no device is available.
