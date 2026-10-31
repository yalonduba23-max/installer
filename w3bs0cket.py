import asyncio
import hashlib
import base64

SSH_HOST = "127.0.0.1"
SSH_PORT = 22
LISTEN_PORT = 8080

WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def make_101_response(key: str) -> bytes:
    accept = base64.b64encode(
        hashlib.sha1((key + WS_MAGIC).encode()).digest()
    ).decode()
    return (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n"
        "\r\n"
    ).encode()


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(4096)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle(client_reader, client_writer):
    addr = client_writer.get_extra_info("peername")
    print(f"[+] Connection from {addr}")

    # Read until end of HTTP headers
    raw = b""
    try:
        while b"\r\n\r\n" not in raw:
            chunk = await asyncio.wait_for(client_reader.read(4096), timeout=10)
            if not chunk:
                break
            raw += chunk
    except asyncio.TimeoutError:
        print("[-] Timeout reading headers")
        client_writer.close()
        return

    header_block = raw.split(b"\r\n\r\n")[0].decode(errors="replace")
    lines = header_block.split("\r\n")
    print(f"[*] Request line: {lines[0]}")

    # Parse headers (last value wins for duplicate Host etc.)
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            k, _, v = line.partition(":")
            headers[k.strip().lower()] = v.strip()

    upgrade = headers.get("upgrade", "").lower()

    if upgrade != "websocket":
        # Decoy response for non-WS requests
        client_writer.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
        await client_writer.drain()
        client_writer.close()
        return

    # Use provided key or fabricate one
    ws_key = headers.get("sec-websocket-key") or \
             base64.b64encode(b"httpinjector0000").decode()

    # Send 101
    client_writer.write(make_101_response(ws_key))
    await client_writer.drain()
    print(f"[*] 101 sent — tunnelling to SSH:{SSH_PORT}")

    # Connect to SSH daemon
    try:
        ssh_reader, ssh_writer = await asyncio.open_connection(SSH_HOST, SSH_PORT)
    except ConnectionRefusedError:
        print("[-] SSH refused — run: sudo systemctl start ssh")
        client_writer.close()
        return

    print("[*] Piping client <-> SSH")
    await asyncio.gather(
        pipe(client_reader, ssh_writer),
        pipe(ssh_reader, client_writer),
    )
    print(f"[-] Session closed {addr}")


async def main():
    server = await asyncio.start_server(handle, "0.0.0.0", LISTEN_PORT)
    print(f"[*] WS-SSH proxy listening on 0.0.0.0:{LISTEN_PORT}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        import uvloop
        asyncio.set_event_loop_policy(uvloop.EventLoopPolicy())
        print("[*] uvloop (epoll) active")
    except ImportError:
        print("[!] uvloop not found — pip install uvloop")

    asyncio.run(main())
