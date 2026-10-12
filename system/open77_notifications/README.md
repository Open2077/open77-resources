# open77_notifications

This resource shows toast notifications on screen: short messages, with an optional progress bar, that any resource can pop up for one player or for everyone.
It is the shared WebUI toast service for Open77 resources. It supports local and server-originated
notifications, six screen positions, four semantic types, custom copy/icon/colour, timed progress,
persistent entries, update, dismissal, broadcast, bounded queues and automatic owner cleanup.

- **Docs:** [WebUI notifications](https://open2077.net/docs/notifications)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

Client packages call the `show`, `update`, `dismiss`, `clear`, `list` and enable-state exports.
Server packages call `Open77.notifications.send`, `broadcast`, `update`, `dismiss` and `clear`;
the runtime automatically scopes every notification to its calling resource.

See [WebUI notifications](https://open2077.net/docs/notifications) for the complete API and examples.
