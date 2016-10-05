
import eventcore.core;
import eventcore.internal.utils;
import std.functional : toDelegate;
import std.socket : InternetAddress;
import std.exception : enforce;
import std.typecons : Rebindable, RefCounted;
import core.thread : Fiber;


Fiber[] store = new Fiber[20000];
size_t storeSize = 0;
Fiber getFiber()
nothrow {

	if (storeSize > 0) return store[--storeSize];
	return new Fiber({});
}
void done(Fiber f)
nothrow {
	if (storeSize < store.length)
		store[storeSize++] = f;
}



struct AsyncBlocker {
	@safe:

	bool done;
	Rebindable!(const(Exception)) exception;
	Fiber owner;

	void start()
	nothrow {
		assert(owner is null);
		done = false;
		exception = null;
		() @trusted { owner = Fiber.getThis(); } ();
	}

	void wait()
	{
		() @trusted { while (!done) Fiber.yield(); } ();
		auto ex = cast(const(Exception))exception;
		owner = null;
		done = false;
		exception = null;
		if (ex) throw ex;
	}

	void finish(const(Exception) e = null)
	nothrow {
		assert(!done && owner !is null);
		exception = e;
		done = true;
		() @trusted { scope (failure) assert(false); if (owner.state == Fiber.State.HOLD) owner.call(); } ();
	}
}

alias StreamConnection = RefCounted!StreamConnectionImpl;

struct StreamConnectionImpl {
	@safe: /*@nogc:*/
	private {
		StreamSocketFD m_socket;
		bool m_empty = false;

		AsyncBlocker writer;
		AsyncBlocker reader;
		ubyte[] m_readBuffer;
		size_t m_readBufferFill;

		ubyte[] m_line;
	}

	this(StreamSocketFD sock, ubyte[] buffer)
	nothrow {
		m_socket = sock;
		m_readBuffer = buffer;
	}

	~this()
	nothrow {
		if (m_socket != StreamSocketFD.invalid)
			eventDriver.sockets.releaseRef(m_socket);
	}

	@property bool empty()
	{
		reader.start();
		eventDriver.sockets.waitSocketData(m_socket, &onData);
		reader.wait();
		return m_empty;
	}

	ubyte[] readLine()
	{
		reader.start();
		if (m_readBufferFill >= 2) onReadLineData(m_socket, IOStatus.ok, 0);
		else eventDriver.sockets.readSocket(m_socket, m_readBuffer[m_readBufferFill .. $], IOMode.once, &onReadLineData);
		reader.wait();
		auto ln = m_line;
		m_line = null;
		return ln;
	}

	void write(const(ubyte)[] data)
	{
		writer.start();
		eventDriver.sockets.writeSocket(m_socket, data, IOMode.all, &onWrite);
		writer.wait();
	}

	void close()
	nothrow {
		eventDriver.sockets.releaseRef(m_socket);
		m_socket = StreamSocketFD.invalid;
		m_readBuffer = null;
	}

	private void onWrite(StreamSocketFD fd, IOStatus status, size_t len)
	@safe nothrow {
		static const ex = new Exception("Failed to write data!");
		writer.finish(status == IOStatus.ok ? null : ex);
	}

	private void onData(StreamSocketFD, IOStatus status, size_t bytes_read)
	@safe nothrow {
		if (status != IOStatus.ok)
			m_empty = true;
		reader.finish();
	}

	private void onReadLineData(StreamSocketFD, IOStatus status, size_t bytes_read)
	@safe nothrow {
		static const ex = new Exception("Failed to read data!");
		static const exh = new Exception("Header line too long.");

		import std.algorithm : countUntil;

		if (status != IOStatus.ok) {
			reader.finish(ex);
			return;
		}

		m_readBufferFill += bytes_read;

		assert(m_readBufferFill <= m_readBuffer.length);

		auto idx = m_readBuffer[0 .. m_readBufferFill].countUntil(cast(const(ubyte)[])"\r\n");
		if (idx >= 0) {
			m_readBuffer[m_readBufferFill .. m_readBufferFill + idx] = m_readBuffer[0 .. idx];
			foreach (i; 0 .. m_readBufferFill - idx - 2)
				m_readBuffer[i] = m_readBuffer[idx+2+i];
			m_readBufferFill -= idx + 2;

			m_line = m_readBuffer[m_readBufferFill + idx + 2 .. m_readBufferFill + idx + 2 + idx];

			reader.finish();
		} else if (m_readBuffer.length - m_readBufferFill > 0) {
			eventDriver.sockets.readSocket(m_socket, m_readBuffer[m_readBufferFill .. $], IOMode.once, &onReadLineData);
		} else {
			reader.finish(exh);
		}
	}
}


void main()
{
	print("Starting up...");
	auto addr = new InternetAddress("127.0.0.1", 8080);
	auto listener = eventDriver.sockets.listenStream(addr, toDelegate(&onClientConnect));
	enforce(listener != StreamListenSocketFD.invalid, "Failed to listen for connections.");

	/*import core.time : msecs;
	eventDriver.setTimer(eventDriver.timers.createTimer((tm) { print("timer 1"); }), 1000.msecs, 1000.msecs);
	eventDriver.setTimer(eventDriver.timers.createTimer((tm) { print("timer 2"); }), 250.msecs, 500.msecs);*/

	print("Listening for requests on port 8080...");
	while (eventDriver.core.waiterCount)
		eventDriver.core.processEvents();
}

void onClientConnect(StreamListenSocketFD listener, StreamSocketFD client)
@trusted /*@nogc*/ nothrow {
	import core.stdc.stdlib;
	auto handler = cast(ClientHandler*)calloc(1, ClientHandler.sizeof);
	handler.client = client;
	auto f = getFiber();
	f.reset(&handler.handleConnection);
	scope (failure) assert(false);
	f.call();

}

struct ClientHandler {
	@safe: /*@nogc:*/ nothrow:

	StreamSocketFD client;

	@disable this(this);

	void handleConnection()
	@trusted {
		ubyte[512] linebuf = void;
		auto reply = cast(const(ubyte)[])"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nKeep-Alive: timeout=10\r\n\r\nHello, World!";

		auto conn = StreamConnection(client, linebuf);
		try {
			while (true) {
				conn.readLine();

				ubyte[] ln;
				do ln = conn.readLine();
				while (ln.length > 0);

				conn.write(reply);
			}
			//print("close %s", cast(int)client);
		} catch (Exception e) {
			print("close %s: %s", cast(int)client, e.msg);
		}
		conn.close();

		done(Fiber.getThis());
	}
}
