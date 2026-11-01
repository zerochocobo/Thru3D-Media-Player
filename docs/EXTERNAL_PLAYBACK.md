# External Android video opening

0.16.2 accepts eligible VIEW/SEND video intents through the dedicated exported entry activity in Debug and Release. The source application must grant access to a supported URI or file. Requests validate scheme/type, bound input/stream lifetime and retain transient content permissions only for the needed lease. They do not copy permanent URI rights or promise every sender, document provider, playlist, codec or protected media.

The Godot host launch guard removes untrusted engine/restart controls before engine startup, retaining only the narrow permitted route. Cross-origin playlist/media requests cannot inherit the source origin's credentials; explicit account authorization, media rights and codec support still apply. Debug contract fixtures are separate from production opening. Build-Player prepares the host guard and verifies actual packaged entry/intent metadata with `Assert-ExternalPlaybackPackaged.ps1`.

Public source includes synthetic contract tests and generic launch preparation, not user intents, provider accounts, signed URLs, credentials, private probe logs or media. Do not infer cross-app/device acceptance from desktop tests alone.
