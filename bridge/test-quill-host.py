"""Exercise worker IPC with a fake Quill library, using the VM's loader."""
from pathlib import Path
import os
import socket
import struct
import subprocess
import sys
import tempfile

loader, worker, library = sys.argv[1:4]
quill = sys.argv[4] if len(sys.argv) > 4 else library
magic = 0x524d5050
with tempfile.TemporaryDirectory() as temp:
    output = Path(temp) / "pixels"
    init = Path(temp) / "init"
    env = dict(os.environ, MOCK_OUTPUT=str(output), MOCK_INIT=str(init))
    base = [loader, worker, "--vendor-lib", library, "--quill-lib", quill]
    subprocess.run(base + ["--probe"], env=env, check=True)
    assert not init.exists(), "ABI probe initialized hardware"
    if not os.environ.get("TEST_REAL_QUILL"):
        assert subprocess.run(base + ["--probe"], env=dict(env, MOCK_QT="wrong"), capture_output=True).returncode != 0
    parent, child = socket.socketpair()
    process = subprocess.Popen(base + ["--fd", str(child.fileno())], pass_fds=[child.fileno()], env=env)
    child.close()
    def receive(n):
        data = b""
        while len(data) < n:
            part = parent.recv(n-len(data))
            assert part, "worker disconnected"
            data += part
        return data
    assert struct.unpack("=4I", receive(16)) == (magic, 1, 8, 6)
    parent.sendall(struct.pack("=5I", magic, 2, 1, 3, 2) + bytes([0, 128, 255, 255, 128, 0]))
    assert struct.unpack("=I", receive(4)) == (magic,)
    image = struct.unpack("=48I", output.read_bytes())
    assert image[1*8+2:1*8+5] == (0xff000000, 0xff808080, 0xffffffff)
    assert image[2*8+2:2*8+5] == (0xffffffff, 0xff808080, 0xff000000)
    assert image[0] == 0 and image[-1] == 0, "dirty rectangle overran framebuffer"
    parent.sendall(struct.pack("=5I", magic, 7, 5, 2, 2))
    assert process.wait(timeout=5) != 0, "out-of-bounds update accepted"
    parent.close()
print("worker ABI probe, version rejection, IPC conversion and bounds tests passed")
