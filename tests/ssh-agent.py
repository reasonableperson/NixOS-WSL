"""Exercise the binary relay using PowerShell's Unix named-pipe transport."""
import base64
import os
import pathlib
import socket
import struct
import subprocess
import tempfile
import threading
import unittest


RELAY = pathlib.Path(os.environ.get("RELAY", "modules/ssh-agent.ps1")).resolve()
COMMAND = ["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand",
           base64.b64encode(RELAY.read_text().encode("utf-16le")).decode()]


def frame(body):
    return struct.pack(">I", len(body)) + body


def receive(stream, length):
    result = b""
    while len(result) < length:
        chunk = stream.recv(length - len(result))
        if not chunk:
            raise EOFError("Truncated response")
        result += chunk
    return result


class RelayTests(unittest.TestCase):
    def test_socket_stdio_and_multiple_requests(self):
        # NamedPipeClientStream uses this Unix socket on non-Windows .NET.
        with tempfile.TemporaryDirectory() as directory:
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(directory + "/CoreFxPipe_openssh-ssh-agent")
            listener.listen()
            listener.settimeout(10)
            errors = []
            request = frame(b"\x0b\x00\xff")
            response = frame(b"\x0c" + bytes(range(256)))

            def agent():
                try:
                    for _ in range(2):
                        connection, _ = listener.accept()
                        with connection:
                            connection.settimeout(10)
                            self.assertEqual(receive(connection, len(request)), request)
                            # Also exercise partial response reads.
                            for byte in response:
                                connection.sendall(bytes([byte]))
                except Exception as error:
                    errors.append(error)

            worker = threading.Thread(target=agent)
            worker.start()
            client, child = socket.socketpair()
            client.settimeout(15)
            process = subprocess.Popen(COMMAND, stdin=child, stdout=child,
                                       stderr=subprocess.PIPE,
                                       env={**os.environ, "TMPDIR": directory})
            child.close()
            try:
                for _ in range(2):
                    for byte in request:
                        client.sendall(bytes([byte]))
                    self.assertEqual(receive(client, len(response)), response)
                client.shutdown(socket.SHUT_WR)
                self.assertEqual(process.wait(timeout=10), 0, process.stderr.read())
            finally:
                client.close()
                if process.poll() is None:
                    process.kill()
                process.wait()
                process.stderr.close()
                worker.join(timeout=15)
                listener.close()
            self.assertFalse(worker.is_alive())
            self.assertEqual(errors, [])

    def test_extensions(self):
        result = subprocess.run(COMMAND, input=frame(b"\x1b") * 2,
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, frame(b"\x06") * 2)

    def test_clean_eof(self):
        result = subprocess.run(COMMAND, input=b"", capture_output=True, timeout=10)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))

    def test_invalid_frames(self):
        for message in [b"\x00", b"\x00\x00\x00\x02\x0b",
                        struct.pack(">I", 0), struct.pack(">I", 262145), b"\xff" * 4]:
            with self.subTest(message=message):
                result = subprocess.run(COMMAND, input=message, capture_output=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertTrue(result.stderr)


if __name__ == "__main__":
    unittest.main()
