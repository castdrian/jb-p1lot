# Discovery and targeting

Run `device_list` and inspect the ID, product, iOS version, connection, bridge,
and pairing fields. Use the stable UDID as `device` for every follow-up call.

When USB and WiFi describe the same UDID, prefer the USBMux path for setup and
large transfers. Disconnecting USB should leave the Bonjour WiFi endpoint on
`_jb-p1lot._tcp` available without changing credentials.

If multiple devices are returned and no selector is supplied, stop and report
the candidates. If no bridge is discovered, check the jailbreak, daemon,
Developer Disk Image, and mTLS identity before attempting package operations.
