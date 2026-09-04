# CalDav Calendar

Add an event from the Omarchy clock. It shows up on your iPhone, Mac, and everywhere else your CalDAV calendar lives.

iCloud, Nextcloud, Fastmail — same two-way sync. Month, week, and day views, meeting links, and reminders, without moving the clock.

<p align="center">
  <img src="screenshots/month.png" alt="Month view" width="800">
</p>

## Install

```bash
omarchy pkg add evolution-data-server
omarchy plugin add https://github.com/SirWizardLizard/omarchy-caldav-calendar --enable
```

This replaces the built-in clock. Shortcuts stay put. If Omarchy leaves the center pin on `omarchy.clock`, the plugin retargets that pin to itself on first run. It does not change a custom or empty pin.

## What it does

- Month, week, work week, and day views
- Create, edit, and delete events (including overnight and recurring) — they sync to your phone and other devices
- iCloud, Nextcloud, Fastmail, and other CalDAV servers
- Calendars that live only on this computer
- Join Zoom, Google Meet, or Teams from a link on the event
- Optional desktop reminder 5–30 minutes before timed events

<p align="center">
  <img src="screenshots/week.png" alt="Week view" width="480">
</p>

## Add iCloud

Do not use your Apple ID password. Apple requires an app-specific password.

1. Open [account.apple.com](https://account.apple.com) → **Sign-In and Security → App-Specific Passwords**
2. Generate a password (2FA must be on)
3. Click the clock → **Add calendar**
4. Enter:

   | Field | Value |
   | --- | --- |
   | Display name | `iCloud` |
   | CalDAV URL | `https://caldav.icloud.com/` |
   | Username | your Apple ID email |
   | Password | the app-specific password |

5. **Add CalDAV source**, then **Sync** if events are not there yet

Remove a calendar later from settings.

## Other CalDAV

Same form. Use the provider’s CalDAV URL and an app password when they require one.

- Nextcloud: `https://your-server/remote.php/dav/`
- Fastmail: `https://caldav.fastmail.com/`

## Meetings

Paste a Zoom, Meet, or Teams URL on the event (`meet.google.com/…` is fine). **Join** opens it. The plugin does not sign in to Google, Zoom, or Outlook.

## Reminders

**Settings → Remind me**: off, or 5 / 10 / 15 / 30 minutes before timed events. Click a meeting toast to join.

<p align="center">
  <img src="screenshots/settings.png" alt="Settings" width="800">
</p>

## Not included

Google Calendar and Outlook need OAuth app review. They are not in this plugin. CalDAV servers and local calendars are.

## Uninstall

```bash
omarchy plugin disable sirwizardlizard.calendar
omarchy plugin remove sirwizardlizard.calendar
```

## Requirements

Omarchy 4, Python 3, and Evolution Data Server (`omarchy pkg add evolution-data-server`). License: MIT.

Credentials stay in the system keyring. They are never written to `shell.json` or this repo.

## Development

```bash
./test/all
omarchy plugin validate .
```
