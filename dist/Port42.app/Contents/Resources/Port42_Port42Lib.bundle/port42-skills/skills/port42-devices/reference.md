# port42-devices reference

The methods for the computer: terminal, screen, camera, audio, files, browser, automation, network. Generated from the running app's registry; do not edit.
Call any of them with `port42 <method> key=value` (`key:=<json>` for numbers, booleans,
arrays and objects; `key=@<file>` for a file's contents).

## audio.capture

_needs the microphone permission_

Start microphone capture. Streams audio.transcription events (and audio.data when rawAudio is set) to the calling port until audio.stopCapture.

    port42 audio.capture

## audio.play

Play base64-encoded audio data (WAV, MP3, AAC).

    port42 audio.play data=…

## audio.speak

Speak text aloud using text-to-speech

        rate (number): Speech rate 0.1-1.0 (default 0.5)
        text (string, required): Text to speak

    port42 audio.speak text=…

## audio.stop

Stop any active speech synthesis or audio playback.

    port42 audio.stop

## audio.stopCapture

_needs the microphone permission_

Stop the microphone capture and release the audio engine.

    port42 audio.stopCapture

## automation.runAppleScript

_needs the automation permission_

Execute AppleScript code and return the result. Use this to control other applications on macOS.

        source (string, required): AppleScript source code
        timeout (integer): Timeout in seconds (default: 30, max: 120)

    port42 automation.runAppleScript source=… timeout=…

## automation.runJXA

_needs the automation permission_

Execute JavaScript for Automation (JXA) code and return the result. Use this to control other applications on macOS.

        source (string, required): JXA source code
        timeout (integer): Timeout in seconds (default: 30, max: 120)

    port42 automation.runJXA source=… timeout=…

## browser.capture

_needs the browser permission_

Take a screenshot of an open browser session. Returns base64 PNG.

        sessionId (string, required): Browser session ID from browser_open

    port42 browser.capture sessionId=…

## browser.close

_needs the browser permission_

Close a browser session

        sessionId (string, required): Browser session ID to close

    port42 browser.close sessionId=…

## browser.execute

_needs the browser permission_

Run JavaScript in an open browser session and return the result.

    port42 browser.execute sessionId=… js=…

## browser.html

_needs the browser permission_

Read the HTML of an open browser session, optionally scoped to a CSS selector.

        options (object): { selector } to scope the read.
        selector (string): CSS selector to read from (default: the whole page).
        sessionId (string, required): The browser session.

    port42 browser.html sessionId=…

## browser.navigate

_needs the browser permission_

Navigate an open browser session to a new URL.

    port42 browser.navigate sessionId=… url=…

## browser.open

_needs the browser permission_

Open a URL in a headless browser and return the page title. Use browser_text to read page content after opening.

        url (string, required): The URL to open (http or https)

    port42 browser.open url=…

## browser.text

_needs the browser permission_

Extract text content from an open browser session

        selector (string): CSS selector to extract from (default: body)
        sessionId (string, required): Browser session ID from browser_open

    port42 browser.text sessionId=…

## camera.capture

_needs the camera permission_

Capture a photo from the device camera. Returns a base64 PNG image.

    port42 camera.capture scale=…

## camera.stopStream

Stop the camera stream and release the capture session.

    port42 camera.stopStream

## camera.stream

_needs the camera permission_

Start continuous camera streaming. Pushes camera.frame events to the calling port until camera.stopStream.

    port42 camera.stream

## clipboard.read

_needs the clipboard permission_

Read the current clipboard contents. Returns text or base64 image data.

    port42 clipboard.read

## clipboard.write

_needs the clipboard permission_

Write text to the system clipboard

        data (string, required): The text to copy to clipboard

    port42 clipboard.write data=…

## fs.list

_needs the filesystem permission_

List the contents of a directory in the Port42 data directory. Relative paths only (e.g. "scopes/strategy" or "scopes/strategy/decisions"). Returns a sorted list of filenames.

        path (string, required): Relative path to the directory (e.g. "scopes/strategy")

    port42 fs.list path=…

## fs.mkdir

_needs the filesystem permission_

Create a directory (and any missing parent directories) in the Port42 data directory. Relative paths only (e.g. "scopes/strategy/decisions").

        path (string, required): Relative path to create (e.g. "scopes/strategy/decisions")

    port42 fs.mkdir path=…

## fs.pick

Open the native file picker. The chosen paths become readable and writable for the calling principal via fs.read / fs.write, with no further permission.

    port42 fs.pick

## fs.read

_needs the filesystem permission_

Read a file. Use a relative path (e.g. "scopes/strategy/scope.md") to read from the Port42 data directory without a file picker. Use an absolute path for picker-approved files.

        encoding (string): utf8 (default) or base64
        path (string, required): Relative path within Port42 data directory (e.g. "scopes/strategy/scope.md") or absolute path for picker-approved files.

    port42 fs.read path=… encoding=…

## fs.write

_needs the filesystem permission_

Write a file. Use a relative path (e.g. "scopes/strategy/facts.md") to write to the Port42 data directory — parent directories are created automatically. Use an absolute path for picker-approved files.

        data (string, required): Content to write
        encoding (string): utf8 (default) or base64
        path (string, required): Relative path within Port42 data directory (e.g. "scopes/strategy/facts.md") or absolute path for picker-approved files.

    port42 fs.write path=… data=… encoding=…

## notify.send

_needs the notification permission_

Send a macOS system notification

        body (string, required): Notification body text
        title (string, required): Notification title

    port42 notify.send title=… body=…

## rest.call

_needs the rest permission_

Make an HTTP request to an external API. Use the 'secret' parameter to inject authentication from the secrets store — you never see the raw credential. Supports GET, POST, PUT, PATCH, DELETE. JSON bodies are auto-serialized. Responses with JSON content-type are auto-parsed.

        body (string): Request body. Objects are JSON-serialized automatically.
        headers (object): Additional HTTP headers as key-value pairs.
        method (string): HTTP method: GET, POST, PUT, PATCH, DELETE. Default: GET.
        secret (string): Named secret from the secrets store. The runtime injects the auth header — you never see the raw key.
        timeout (integer): Timeout in milliseconds. Default: 30000, max: 120000.
        url (string, required): Full URL to call (https recommended)

    port42 rest.call url=…

## screen.capture

_needs the screen permission_

Capture a screenshot of the screen. Returns a base64 PNG image.

        scale (number): Image scale factor 0.1-2.0 (default 1.0)

    port42 screen.capture scale=…

## screen.displays

Get display information: size, position, and visible area (excluding dock/menubar) for all connected displays. No screen recording permission required. Use this to calculate port positions before calling port_move.

    port42 screen.displays

## screen.record

_needs the screen permission_

Record an app surface for a fixed number of seconds and auto-stop (the convenience form). Pass options.seconds. Returns {path, width, height, seconds, fps, bytes}.

        options (object): Recording options: target ({window:"self"} | {window:<osId>} | {port:<udid>} | {ports:[<udid>...]} | {region:{x,y,w,h}} | {display:<id>}). window/port/ports are occlusion-proof (only that surface); region/display capture the raw display (may catch other apps). Also aspect (e.g. "16:9"), fit (cover|exact; contain is not yet supported), width, height, scale, fps, padding, cursor (bool; only on a display or region target — a window/port capture cannot include the cursor), audio (none|system|mic|both), format (mov|mp4), path, and for the convenience form seconds.

    port42 screen.record

## screen.record.start

_needs the screen permission_

Start recording an app surface (window:self / a port / multiple ports) to a video file with optional system or mic audio. Returns {recordingId, width, height, target}. Stop with screen.record.stop.

        options (object): Recording options: target ({window:"self"} | {window:<osId>} | {port:<udid>} | {ports:[<udid>...]} | {region:{x,y,w,h}} | {display:<id>}). window/port/ports are occlusion-proof (only that surface); region/display capture the raw display (may catch other apps). Also aspect (e.g. "16:9"), fit (cover|exact; contain is not yet supported), width, height, scale, fps, padding, cursor (bool; only on a display or region target — a window/port capture cannot include the cursor), audio (none|system|mic|both), format (mov|mp4), path, and for the convenience form seconds.

    port42 screen.record.start

## screen.record.status

Report whether a recording (or any recording) is active and its elapsed seconds.

        recordingId (string): Optional recording id; omit for the overall status

    port42 screen.record.status recordingId=…

## screen.record.stop

Stop a recording started with screen.record.start. Returns {path, width, height, seconds, fps, bytes}.

        recordingId (string, required): The id returned by screen.record.start

    port42 screen.record.stop recordingId=…

## screen.stopStream

Stop the screen stream and release the capture stream.

    port42 screen.stopStream

## screen.stream

_needs the screen permission_

Start continuous screen streaming. Pushes screen.frame events to the calling port until screen.stopStream.

    port42 screen.stream

## screen.windows

_needs the screen permission_

List all visible windows with their titles, apps, and positions

    port42 screen.windows

## terminal.exec

_needs the terminal permission_

Execute a shell command and return the output. Runs in /bin/zsh.

        command (string, required): The shell command to execute
        cwd (string): Working directory (default: home)
        timeout (integer): Timeout in seconds (default: 30, max: 120)

    port42 terminal.exec command=…
