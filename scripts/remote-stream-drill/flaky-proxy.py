"""Forwards 0.0.0.0:4600 to a server on 127.0.0.1:4599 and, while a file named flaky sits beside this script, cuts every response after the byte count given as the first argument (default 400000). The rig for --exercise-remote-stream."""
import asyncio, os, sys
UP = ("127.0.0.1", 4599)
CUT = int(sys.argv[1]) if len(sys.argv) > 1 else 400_000
FLAG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "flaky")
async def pipe(reader, writer, limit):
    sent = 0
    try:
        while data := await reader.read(65536):
            if limit and os.path.exists(FLAG) and sent + len(data) > limit:
                writer.write(data[: max(0, limit - sent)])
                await writer.drain()
                print("cut after", limit, flush=True)
                break
            writer.write(data)
            await writer.drain()
            sent += len(data)
    except Exception:
        pass
    finally:
        writer.transport.abort()
async def handle(reader, writer):
    try:
        up_r, up_w = await asyncio.open_connection(*UP)
    except Exception:
        writer.close(); return
    await asyncio.gather(pipe(reader, up_w, 0), pipe(up_r, writer, CUT))
async def main():
    server = await asyncio.start_server(handle, "0.0.0.0", 4600)
    async with server:
        await server.serve_forever()
asyncio.run(main())
