# Windows self-extracting package

This optional packaging template takes a Windows ZIP converted to a solid
LZMA2/7z payload. Compile `Program.cs` with that payload and an official
`7zr.exe` embedded as resources. Running the resulting unsigned
executable:

1. asks for an extraction directory, defaulting to the current user's
   `%LOCALAPPDATA%\Programs\HarborProxy` and requests administrator permission;
2. asks whether to create the current user's desktop `HarborProxy.lnk`;
3. extracts the immutable 7z payload with the embedded official extractor;
4. removes the retired `HarborProxyHelperService` during an upgrade;
5. leaves application data under the normal per-user HarborProxy data directory.

The ZIP is an intermediate build input. Installation
uses a staged directory swap: the previous application tree is retained only
for rollback and removed after a successful install. The bundled 7-Zip license
is installed as `7-Zip-LICENSE.txt` beside `HarborProxy.exe`.

Automated release validation may pass `--silent`, `--target <directory>`, and
`--shortcut` or `--no-shortcut`; ordinary double-click use shows the interactive
dialog and a completion or error message. `app.manifest` fixes the execution
level to `requireAdministrator`, matching the elevated Windows GUI that starts
`HarborProxyCore.exe` directly.
