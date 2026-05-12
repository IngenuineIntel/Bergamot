# net.pyx

from interface import l
import protocol

# ── TCP sender with reconnect back-off ───────────────────────────────────── #

cdef class Sender:
    cdef str _host
    cdef int _port
    cdef object _sock
    cdef double _backoff
    cdef dict _system_info

    def __init__(self, str host, int port):
        self._host = host
        self._port = port
        self._sock = None
        self._backoff = 1.0
        self._system_info = collect_system_info()

    cdef bint _connect(self):
        cdef object s
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(SOCKET_TIMEOUT_SECONDS)
            s.connect((self._host, self._port))
            s.settimeout(None)
            self._sock = s
            self._backoff = 1.0
            if not self._send_objects([self._system_info]):
                self._close()
                l.critical("failed to send system_info handshake", flush=True)
                l.info(f"retrying in {self._backoff:.0f}s", flush=True)
                time.sleep(self._backoff)
                self._backoff = min(self._backoff * 2, RECONNECT_MAX_SECONDS)
                return False
            l.info(f"connected to {self._host}:{self._port}", flush=True)
            return True
        except OSError as exc:
            l.error(f"connect failed: {exc}", flush=True)
            l.info(f"retrying in {self._backoff:.0f}s", flush=True)
            time.sleep(self._backoff)
            self._backoff = min(self._backoff * 2, RECONNECT_MAX_SECONDS)
            return False

    cpdef void connect(self):
        while not self._connect():
            pass

    cpdef bint send_batch(self, list events):
        """
        Encode and send a batch of events.  Returns False if the connection
        was lost; caller should reconnect and retry.
        """
        if not events:
            return True

        return self._send_objects(events)

    cdef bint _send_objects(self, list payloads):
        cdef str payload
        cdef bytes data
        cdef object obj
        cdef bytes bin_payload
        cdef int kind
        cdef list frames
        cdef int dropped_frames = 0
        if self._sock is None:
            return False

        frames = []
        for obj in payloads:
            if not isinstance(obj, dict):
                continue

            kind, bin_payload = protocol.encode_wire_payload(obj)

            if len(bin_payload) > MAX_FRAME_BYTES:
                dropped_frames += 1
                continue

            frames.append(protocol.encode_frame(kind, bin_payload))

        if dropped_frames:
            l.warning(f"dropped {dropped_frames} oversized frame(s)")

        if not frames:
            return True

        data = b"".join(frames)

        try:
            self._sock.sendall(data)
            return True
        except OSError as exc:
            l.error(f"send error: {exc}", flush=True)
            self._close()
            return False

    cdef void _close(self):
        if self._sock:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
