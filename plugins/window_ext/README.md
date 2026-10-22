# window_ext

Desktop window extensions exposed through Flutter's `window_ext` method channel.

`lib/window_ext.dart` exports the shared `windowExtManager` and `WindowExtListener` API:

- subscribe to `taskbarCreated` and `shouldTerminate` notifications;
- add and remove event listeners;
- request rounded or square window corners with `setWindowCornerPreference`.

Native implementations and supported operations are maintained in the platform directories.
