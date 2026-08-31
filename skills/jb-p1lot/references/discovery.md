# Discovery and targeting

Run `device_list` and inspect the ID, product, iOS version, connection, bridge,
and pairing fields. Use the stable UDID as `device` for every follow-up call.

USB and WiFi entries for one UDID are merged. USBMux is preferred for setup
and large transfers, while Bonjour `_jb-p1lot._tcp` keeps encrypted WiFi
available after USB disconnects. Multiple candidates require an explicit
selector.
