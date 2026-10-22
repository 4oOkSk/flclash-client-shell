package tun

// Android's VpnService interface and Mihomo userspace listener must advertise
// the same non-jumbo MTU. Keeping both at the ordinary underlay ceiling avoids
// silent large-flow stalls when an IPv6 path drops PMTU feedback.
const androidTUNMTU = 1500
