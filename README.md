# nuvo-zone-keepalive

Keeps a Nuvo Player Portfolio zone (P100 / P200 / P3100 / P3500 / P4300)
"awake" and set to Line In, without ever touching the Nuvo Player app.

## Background

Nuvo's Player Portfolio app periodically drops an idle zone out of its
active playback group — you'll see it fall back into a "drag zone here to
start" tray in the app. When that happens, audio silently stops reaching
the zone until someone manually re-drags it into the group in the app.
There's no documented API and no setting to disable this behavior.

This project replays the same two local network calls the app itself
makes when you perform that drag — reverse-engineered from a decrypted
WiFi capture of the app in action — so you can trigger them automatically
(e.g. right before an AirPlay stream starts) instead of doing it by hand.

**This is unofficial and reverse-engineered.** It talks to a UPnP-based
control interface (`urn:schemas-nuvotechnologies-com:service:Zone:1` and
a Nuvo extension of the standard `AVTransport` service) that Nuvo has not
published or documented. It was built and tested against one P3100 unit;
it is very likely to work the same way on other Player Portfolio models
since they share the same app and appear to share the same control
protocol, but that hasn't been verified. There's no guarantee Nuvo won't
change this in a future firmware/app update. Use at your own risk.

See the Quick Start below to get running, or "Finding your
`NUVO_MEMBER_MAC`" and "Exploring the API further" for detail on the two
included helper scripts (`list_zones.py`, `list_actions.py`).

## Requirements

- `bash`, `curl`, `python3` (standard library only, no extra packages)
- Your Nuvo zone and the machine running these scripts on the same LAN
  and broadcast domain (SSDP relies on multicast, so this won't work
  across routed VLANs/subnets without multicast relaying)

## Quick Start

The condensed happy path, assuming SSDP mode with systemd (the
recommended default). See the sections below for static mode, cron
instead of systemd, and troubleshooting detail.

```bash
# 1. Get the code
git clone <this-repo> /opt/nuvo-zone-keepalive
cd /opt/nuvo-zone-keepalive
cp config.example.conf config.conf

# 2. Find your zone's MAC and name
./list_zones.py
```

Copy the `NUVO_MEMBER_MAC` and zone name for the zone you want from the
output into `config.conf`.

**Before continuing:** shairport-sync's hook (step 7 below) runs
`wake_zone.sh` as shairport-sync's own service user, not as you — find
that user now so steps 3-7 are owned consistently (see "Running as the
shairport-sync user" below for the full explanation):

```bash
systemctl show shairport-sync -p User -p Group
# e.g. User=shairport-sync Group=shairport-sync -- use that below.
# If both come back empty, shairport-sync runs as root; see the note below.
```

```bash
# 3. Create and correctly own the data directory FIRST, before starting
#    anything that writes into it -- doing this after starting the timer
#    risks a race where step 4 checks a file that doesn't exist yet.
sudo mkdir -p /var/lib/nuvo-zone-keepalive
sudo chown shairport-sync:shairport-sync /var/lib/nuvo-zone-keepalive

# 4. Start the discovery poller, so wake_zone.sh always knows how to
#    reach the zone even if its IP/port ever changes
sudo cp systemd/nuvo-discover.* /etc/systemd/system/
sudo nano /etc/systemd/system/nuvo-discover.service   # set User=/Group= to match
sudo mkdir -p /etc/nuvo-zone-keepalive
sudo cp config.conf /etc/nuvo-zone-keepalive/config.conf
sudo systemctl daemon-reload
sudo systemctl enable --now nuvo-discover.timer

# 5. Confirm discovery is working (give it a few seconds to run first)
sleep 5
cat /var/lib/nuvo-zone-keepalive/discovery-cache.conf
# should show a real ZONE_CONTROL_URL and AVTRANSPORT_CONTROL_URL

# 6. Test the wake sequence AS that user (not as yourself) so you're
#    testing the same permissions shairport-sync's hook will actually
#    run under
chmod +x wake_zone.sh
sudo -u shairport-sync ./wake_zone.sh
```

Check `wake_zone.log` — a successful `GroupCreate` returns a `<groupID>`,
and a successful `X_NUVO_PlayContainerURI` returns an empty response
with no `<s:Fault>`. If both look clean, your zone should now show as
active with Line In selected in the Nuvo app — with zero taps.

```bash
# 7. Wire it up so it runs automatically, e.g. right before AirPlay
#    playback starts (adjust the path to match where you cloned this)
```

See `examples/shairport-sync-sessioncontrol.conf` — merge it into
`/etc/shairport-sync.conf`, then `sudo systemctl restart shairport-sync`.
Not using shairport-sync? `wake_zone.sh` is a standalone script and can
be triggered from cron, another hook, or anywhere else you can shell out
from. There's also an optional `tear_zone_down.sh` companion for cleaning
up immediately on stop rather than on the next start — see "Tearing the
zone down on stop" below; most people can skip it.

That's the whole setup. Everything past this point is reference detail:
what each piece does, static-mode/cron alternatives, multi-zone setups,
and how to explore the Nuvo's API further.

## How it works

1. **`discover.py`** — finds your Nuvo zone on the network via SSDP,
   reads its device description XML for the real control URLs, and
   caches them to a file. Meant to run on a timer (e.g. every 60s) so the
   cache self-heals if the zone's IP or port ever changes. On failure it
   leaves the existing cache alone rather than erasing a working value.
2. **`wake_zone.sh`** — reads the cached (or statically configured)
   control URLs, then makes three SOAP calls against the Nuvo:
   - `GroupDisband` on the group it created *last time* (if any) — cleans
     up before creating a new one, so groups don't pile up indefinitely.
     Best-effort: if that group is already gone for any reason, this
     simply faults harmlessly and is logged, not treated as fatal.
   - `GroupCreate` on the Zone service — this is what "drag zone into
     start" actually does; it (re)activates the zone's playback group.
     The returned groupID is saved so next run can disband it.
   - `X_NUVO_PlayContainerURI` on the AVTransport service — selects Line
     In as the zone's active source. This call depends on internal state
     set by `GroupCreate`, so it must run after it, every time.

Run `wake_zone.sh` from wherever makes sense for your use case — a
shairport-sync `run_this_before_play_begins` hook (see
`examples/shairport-sync-sessioncontrol.conf`) is the intended use case,
but it's a standalone script and works from cron, a systemd hook, or
anywhere else you can shell out from.

### Tearing the zone down on stop (optional)

`tear_zone_down.sh` is an optional companion for the reverse hook,
`run_this_after_play_ends`. It disbands the group `wake_zone.sh` created,
immediately, instead of leaving it for either the Nuvo's own idle timeout
or the next `wake_zone.sh` run to clean up. On a successful disband it
also clears the group-state file, so that next `wake_zone.sh` run doesn't
waste a call re-disbanding a group that's already gone.

This is a tidiness improvement, not a fix for anything broken —
`wake_zone.sh` already disbands the *previous* group before creating a
new one regardless, so at most one orphaned group exists at any given
time either way, and the Nuvo's own idle timeout (the whole reason this
project exists) will very likely clean up an inactive group on its own
before you'd notice. Skip this script entirely if you don't care whether
the zone briefly still shows as "active" in the app for a while after
playback actually stops. To enable it, see the commented-out line in
`examples/shairport-sync-sessioncontrol.conf`.

`wake_zone.sh` and `tear_zone_down.sh` share their config-loading and
control-URL-resolution logic via `common.sh`, so the two scripts can't
drift out of sync with each other over time.

## Installation reference

The Quick Start above covers the recommended path (SSDP mode + systemd).
This section covers the alternatives.

### Cron instead of systemd

If you'd rather not deal with systemd units, run discovery via cron
instead of the `nuvo-discover.timer` from the Quick Start:

```
* * * * * /usr/bin/python3 /opt/nuvo-zone-keepalive/discover.py --config /opt/nuvo-zone-keepalive/config.conf
```

### Static mode (no discovery poller at all)

If you'd rather not run a discovery poller at all, set
`NUVO_DISCOVERY_MODE="static"` in `config.conf` and fill in
`NUVO_STATIC_HOST` / `NUVO_STATIC_ZONE_CONTROL_PATH` /
`NUVO_STATIC_AVTRANSPORT_CONTROL_PATH`. You can find these by browsing to
the device description URL from `list_zones.py`'s output once, or by
capturing one request as described in "Finding your `NUVO_MEMBER_MAC`"
below. This is simpler, but will break silently if the Nuvo's IP or port
ever changes — steps 3-5 of the Quick Start (the discovery poller) don't
apply in this mode, skip straight to step 6 (testing).

### Running as the shairport-sync user

This is the detail behind steps 3 and 5 of the Quick Start, and worth
reading in full if anything about permissions goes wrong.

shairport-sync almost always runs as its own dedicated, unprivileged
system user (commonly `shairport-sync`), not as root and not as whatever
user you're logged in as when you install this. When it invokes
`run_this_before_play_begins`, the hook script runs as *that* user — so
if the cache file, the group-state file, the log file, or even
`wake_zone.sh` and its sibling `lineIn-body-template.xml` aren't readable
(and, for the state/log files, writable) by that specific user, the hook
will silently fail every time shairport-sync calls it, even though
everything worked fine when you ran it yourself.

The simplest fix is to make everything consistently owned by that one
user, so there's no cross-user boundary to cross at all:

1. **Find the user:**
   ```bash
   systemctl show shairport-sync -p User -p Group
   ```
   If this prints real values (e.g. `User=shairport-sync`), that's your
   user for everything below. **If both come back empty**, shairport-sync
   is running as root, in which case there's actually no permission
   problem to solve — root can read/write everything already, and you
   can skip the rest of this section.

2. **Own the data directory by that user** (already in Quick Start step
   3, repeated here for reference):
   ```bash
   sudo mkdir -p /var/lib/nuvo-zone-keepalive
   sudo chown shairport-sync:shairport-sync /var/lib/nuvo-zone-keepalive
   ```
   This covers `NUVO_CACHE_FILE`, `NUVO_GROUP_STATE_FILE`, and
   `NUVO_LOG_FILE`, since all three default into this one directory.

3. **Run the discovery poller as that same user** — set `User=`/`Group=`
   in `nuvo-discover.service` before enabling the timer (the shipped
   template already has placeholder values; update them to match what
   step 1 printed).

4. **Make sure the installed code itself is readable.** If you cloned
   this repo as root or another user into `/opt/nuvo-zone-keepalive`,
   confirm the shairport-sync user can at least read and execute it:
   ```bash
   sudo -u shairport-sync test -r /opt/nuvo-zone-keepalive/wake_zone.sh && echo OK
   ```
   A normal `git clone` typically leaves files world-readable by default,
   so this is usually already fine — but worth confirming rather than
   assuming, especially if you `chmod`'d anything restrictively along the
   way.

5. **Test as that user, not as yourself** — this is the one that
   actually matters, since testing as your own login user can pass even
   when the real hook would fail:
   ```bash
   sudo -u shairport-sync /opt/nuvo-zone-keepalive/wake_zone.sh
   ```
   Check `wake_zone.log` afterward the same way as usual. If this
   succeeds, the shairport-sync hook will too.

**If shairport-sync's systemd unit uses sandboxing directives** (check
with `systemctl cat shairport-sync` — look for `ProtectSystem=`,
`ProtectHome=`, `ReadWritePaths=`, `NoNewPrivileges=`, etc.), those can
block file access or script execution even with correct ownership. If
steps 1-5 above all check out but the hook still silently fails, this is
the next thing to look at — you may need to add
`/var/lib/nuvo-zone-keepalive` and wherever you installed this repo to
shairport-sync's `ReadWritePaths=`/`ReadOnlyPaths=`.

## Finding your `NUVO_MEMBER_MAC`

Each zone identifies itself by its MAC address (no colons, lowercase),
used as `memberId-<mac>` throughout the protocol. The MAC is still a
required setting — `wake_zone.sh` needs to know exactly which zone to
act on, since a household can have more than one — but finding it is
easy:

```bash
./list_zones.py
```

This searches SSDP for every Nuvo zone on your network, then calls each
one's `Get` action to read its actual configured name (`Title`) — not
just the device's generic UPnP `friendlyName`, which turns out to just
be `"NuVo Zone <mac>"` boilerplate, not useful on its own. Output looks
like:

```
Zone name    NUVO_MEMBER_MAC Device description URL
----------------------------------------------------
Kitchen      0025ed1e7c0b    http://192.168.50.145:58587/...
Living Room  0025ed1e7c12    http://192.168.50.152:58587/...
```

Copy the row for the zone you want straight into `config.conf`.

If for some reason a zone doesn't show up here (not discoverable via
SSDP, or you want to verify the value independently), you can fall back
to finding it in a packet capture instead: capture the Nuvo app
performing a zone action and look for `memberId-XXXXXXXXXXXX` in the
decrypted SOAP body. This requires decrypting your own WiFi capture
(WPA2 networks only — WPA3/SAE can't be decrypted after the fact even
with the password). Broad strokes: ARP-spoof or monitor-mode capture the
traffic between the Nuvo app and the Nuvo zone while triggering a zone
action in the app, decrypt it in Wireshark, and look for the
`GroupCreate` or `X_NUVO_PlayContainerURI` SOAP request.

## Exploring the API further

`list_actions.py` walks a device's UPnP description and prints every
action every service publishes, along with each argument's direction and
related state variable — pulled straight from the device's own SCPD
(Service Control Protocol Description) documents, not guessed from
captures. Useful if you want to find other things to automate, or to
check what a Nuvo model/firmware you're not the same as supports.

```bash
./list_actions.py --discover <member_mac>
# or, if you already have the device description URL:
./list_actions.py http://<nuvo-ip>:<port>/<uuid>.xml
```

A few other actions turned up this way, tested since the first version of
this project:

- **`Zone#UserTap`** — takes no input, returns a `groupID`. Tested: it
  behaves identically to `GroupCreate` (creates a group, but does not
  touch source selection), so it offers no advantage over the
  `GroupCreate` call this project already uses. Not integrated.
- **`Zone#GroupDisband`** — takes a `groupID`. Tested and integrated (see
  above) — this is what keeps orphaned groups from piling up.
- **`Zone#GroupMemberSetGroup`** — takes `memberIDs` *and* an existing
  `groupID`; looks like "add members to an already-active group" rather
  than creating a new one. This is really a multi-zone synchronized-
  listening feature (joining a session already playing on a *different*
  zone) rather than a fit for the single-independent-zone use case this
  project targets, so it wasn't pursued further. Worth exploring if your
  use case involves multiple zones joining a shared, already-playing
  session.
- **`RenderingControl`** service — standard `GetVolume`/`SetVolume`/
  `GetMute`/`SetMute`, plus `X_NUVO_AdjustVolume`. Unrelated to the zone
  keep-alive problem this project solves, but trivially scriptable with
  the same approach if useful to you.

## Multiple zones

Run separate copies of `wake_zone.sh` (and, if you want separate
discovery caches, separate `discover.py` instances) with different config
files, one per zone — e.g. `config-kitchen.conf`, `config-living-room.conf`.
Each zone's `NUVO_MEMBER_MAC` is independent.

## Known limitations / things to verify on your setup

- SSDP relies on multicast; this generally won't traverse routed
  VLANs/subnets or some mesh WiFi configurations without extra multicast
  relaying/bridging. If discovery consistently fails, confirm the machine
  running `discover.py` is on the same broadcast domain as the Nuvo.
- Built and tested against a Nuvo P3100. Zone naming, service paths, and
  behavior are assumed (not confirmed) to be the same across the rest of
  the Player Portfolio line.
- `wake_zone.sh` tracks the groupID it created last time in
  `NUVO_GROUP_STATE_FILE` and disbands it before creating a new one. If
  that file is ever deleted or gets out of sync (e.g. someone manually
  tore the zone down in the app since), the next run just logs a harmless
  fault from `GroupDisband` and moves on — it self-heals rather than
  failing outright.

## License

MIT — see `LICENSE`. Adjust or remove as you like for your own fork.
