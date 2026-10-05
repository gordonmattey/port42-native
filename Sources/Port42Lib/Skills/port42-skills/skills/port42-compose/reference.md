# port42-compose reference

The methods for ports feeding ports, and reacting to them. Generated from the running app's registry; do not edit.
Call any of them with `port42 <method> key=value` (`key:=<json>` for numbers, booleans,
arrays and objects; `key=@<file>` for a file's contents).

## port.publish

A port emits its OWN state or event on its own Notify topic, for consumers watching via port_subscribe. This is a port broadcasting AS itself — distinct from port_push, which is input sent INTO a port. Only meaningful from inside a port; the topic is the calling port's own id, so there is no target argument. Use this instead of having a consumer reach in with port_exec to read state: the port publishes, consumers subscribe.

        kind (string, required): Event kind, e.g. 'state', 'progress', 'error'. Namespaced on the way out: you publish 'state', subscribers see 'port.state', so a port cannot emit a system event like 'driver' or 'browser.load'.
        payload: Any JSON value (object/array/string/number) delivered as the Notify envelope's payload.

    port42 port.publish kind=… payload=…

## port.subscribe

_streaming: over the gateway's WebSocket, not the command_

Subscribe to a port's live event stream. Yields Notify events { topic, kind, payload, token } as the port emits them (e.g. terminal.output), after a first `subscribed` event that says the stream is live: read anything you need to catch up on then. `token` is the port's state token AT THAT MOMENT, so you can write next without re-reading the port first. OVER THE GATEWAY THIS IS WEBSOCKET-ONLY: connect to /ws and send it as a `call` envelope, and events arrive as `stream` frames on the same call_id. On HTTP /call it is refused with `unsupported`, because the stream never ends and a request/response call could only hang. The stream stays open until cancelled.

        id (string, required): The port to observe (id / udid / title).

## timer.after

From a port's page: call back once, after `seconds`, as port42.timer.after(seconds, fn). Paced as timer.every: while the port is not on screen it may fire later, and fires when the port is shown again. Returns { id }.

        id (string): The timer's id, chosen by the page (the port42 library does this); else Port42 makes one.
        seconds (number, required): Seconds between ticks (at least 0.25).

    port42 timer.after seconds=… id=…

## timer.cancel

From a port's page: stop a timer, by the id timer.every or timer.after returned (port42.timer.cancel(id)). A port's timers also stop when it closes or its page reloads.

        id (string, required): The timer's id.

    port42 timer.cancel id=…

## timer.every

From a port's page: call back every `seconds`, as port42.timer.every(seconds, fn), which returns the timer's id. Use it instead of setInterval: Port42 owns the clock, runs it at full rate while the port is on screen or set to run in the background, slows it to once a minute while the port is in another space, paused or hidden, and fires it at once when the port is shown again. Returns { id }.

        id (string): The timer's id, chosen by the page (the port42 library does this); else Port42 makes one.
        seconds (number, required): Seconds between ticks (at least 0.25).

    port42 timer.every seconds=… id=…
