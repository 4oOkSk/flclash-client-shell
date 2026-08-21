# Windows self-extracting package

The release process converts the verified private Windows ZIP to a solid
LZMA2/7z payload, then compiles `Program.cs` with that payload and the pinned
official `7zr.exe` embedded as resources. Running the resulting unsigned
executable:

1. asks for an extraction directory, defaulting to the current user's
   `%LOCALAPPDATA%\Programs\HarborProxy` (no administrator permission required);
2. asks whether to create the current user's desktop `HarborProxy.lnk`;
3. extracts the immutable 7z payload with the embedded official extractor;
4. leaves application data under the normal per-user HarborProxy data directory.

The ZIP is only an intermediate build input and is not shipped. The
self-extractor does not delete an existing target directory; files present in
the payload are replaced, while unrelated files are preserved. The bundled
7-Zip license is installed as `7-Zip-LICENSE.txt` beside `HarborProxy.exe`.

Automated release validation may pass `--silent`, `--target <directory>`, and
`--shortcut` or `--no-shortcut`; ordinary double-click use shows the interactive
dialog and a completion or error message. `app.manifest` fixes the execution
level to `asInvoker` so the wrapper never requests elevation on its own.
