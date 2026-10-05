#!/usr/bin/env python3
"""Loopback-only SSH/SFTP fixture. Stores data only under a fresh temp directory."""
import base64, json, os, socket, threading, tempfile, subprocess, sys, time
import paramiko
root = tempfile.mkdtemp(prefix='tabby-native-sftp-')
key = paramiko.ECDSAKey.generate()
keypath = os.path.join(root, 'client-key')
subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', keypath], check=True)
clientkey = paramiko.Ed25519Key.from_private_key_file(keypath)

def monitoring_sample(path, step):
    """Advance only synthetic monotonic counters for consecutive GUI samples."""
    with open(path, 'r') as sample_file: first = sample_file.read()
    stem, extension = os.path.splitext(path)
    next_path = stem + '-next' + extension
    if not step or not os.path.isfile(next_path): return first.encode()
    with open(next_path, 'r') as sample_file: second = sample_file.read()
    next_rows = {row.split('\t', 2)[0]: row.split('\t', 2) for row in second.splitlines() if '\t' in row}
    result = []
    for row in first.splitlines():
        fields = row.split('\t', 2)
        if len(fields) != 3 or fields[0] not in ('system', 'cpu', 'diskIO', 'interfaces'):
            result.append(row); continue
        newer = next_rows.get(fields[0])
        if not newer: result.append(row); continue
        before = base64.b64decode(fields[2]).decode().splitlines()
        after = base64.b64decode(newer[2]).decode().splitlines()
        advanced = []
        for left, right in zip(before, after):
            if fields[0] == 'system':
                if left.startswith('uptime=') and right.startswith('uptime='):
                    old, new = float(left[7:]), float(right[7:])
                    left = 'uptime=' + str(old + (new - old) * step)
                advanced.append(left); continue
            old_fields, new_fields = left.split(), right.split()
            if len(old_fields) != len(new_fields): advanced.append(left); continue
            values = []
            for old, new in zip(old_fields, new_fields):
                if old.isdecimal() and new.isdecimal() and int(new) >= int(old):
                    values.append(str(int(old) + (int(new) - int(old)) * step))
                else: values.append(old)
            advanced.append(' '.join(values))
        fields[2] = base64.b64encode('\n'.join(advanced).encode()).decode()
        result.append('\t'.join(fields))
    return ('\n'.join(result) + '\n').encode()

class Server(paramiko.ServerInterface):
    def __init__(self): self.destinations = {}; self.forwards = {}; self.transport = None; self.monitoring_count = 0
    def check_port_forward_request(self, address, port):
        if address != "127.0.0.1": return False
        sock = socket.socket(); sock.bind((address, port)); sock.listen(10)
        actual = sock.getsockname()[1]; self.forwards[(address, actual)] = sock
        def accept():
            while True:
                try:
                    peer, origin = sock.accept()
                    channel = self.transport.open_channel("forwarded-tcpip", (address, actual), origin)
                    threading.Thread(target=relay_peers, args=(channel, peer), daemon=True).start()
                except Exception: break
        threading.Thread(target=accept, daemon=True).start()
        return actual
    def cancel_port_forward_request(self, address, port):
        sock = self.forwards.pop((address, port), None)
        if sock: sock.close()
    def check_channel_direct_tcpip_request(self, channel_id, origin, destination):
        # This fixture-only hostname verifies that SOCKS domains reach the SSH
        # server unchanged, without client-side DNS or external network access.
        if destination == ("axon-socks.test", echo_listener.getsockname()[1]):
            destination = ("127.0.0.1", destination[1])
        if destination not in [("127.0.0.1", listener.getsockname()[1]), ("127.0.0.1", echo_listener.getsockname()[1])]: return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        self.destinations[channel_id] = destination
        return paramiko.OPEN_SUCCEEDED
    def check_auth_password(self, user, password):
        return paramiko.AUTH_SUCCESSFUL if (user, password) == ('test', 'test-password') else paramiko.AUTH_FAILED
    def check_auth_publickey(self, user, pub):
        return paramiko.AUTH_SUCCESSFUL if user == 'test' and pub == clientkey else paramiko.AUTH_FAILED
    def get_allowed_auths(self, user): return 'password,publickey'
    def check_channel_request(self, kind, cid): return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_pty_request(self, *args): return True
    def check_channel_shell_request(self, channel):
        threading.Thread(target=shell, args=(channel,), daemon=True).start(); return True
    def check_channel_window_change_request(self, *args): return True
    def check_channel_exec_request(self, channel, command):
        def run():
            time.sleep(0.05)
            # Optional synthetic Linux response for native monitoring UI/SSH tests.
            # The server remains loopback-only; ordinary exec and SFTP still work.
            sample_path = os.environ.get('TABBY_TEST_MONITOR_SAMPLE')
            if sample_path and b'AXON_MONITOR_V1' in command:
                sample = monitoring_sample(sample_path, self.monitoring_count)
                self.monitoring_count += 1
                try:
                    channel.sendall(sample); channel.send_exit_status(0); channel.close()
                except Exception: pass  # Cancellation closes only this exec channel.
            else:
                out = subprocess.run(command, shell=True, cwd=root, capture_output=True)
                try:
                    channel.sendall(out.stdout); channel.sendall_stderr(out.stderr); channel.send_exit_status(out.returncode); channel.close()
                except Exception: pass
        threading.Thread(target=run, daemon=True).start(); return True

def shell(channel):
    channel.sendall(b'test-shell> ')
    pending = b''
    try:
        while True:
            data = channel.recv(4096)
            if not data: break
            pending += data
            while b'\n' in pending:
                cmd, pending = pending.split(b'\n', 1)
                if cmd.strip() == b'exit': channel.send_exit_status(0); channel.close(); return
                out = subprocess.run(cmd.decode(), shell=True, cwd=root, capture_output=True)
                channel.sendall(out.stdout); channel.sendall_stderr(out.stderr)
    except Exception: pass

class SFTP(paramiko.SFTPServerInterface):
    def resolve(self, path):
        result = os.path.abspath(os.path.join(root, path.lstrip('/')))
        if os.path.commonpath([result, root]) != root: raise PermissionError('outside fixture')
        return result
    def canonicalize(self, path): return '/' + os.path.relpath(self.resolve(path), root).replace(os.sep, '/').strip('.')
    def list_folder(self, path):
        try:
            result = []
            for name in os.listdir(self.resolve(path)):
                attr = paramiko.SFTPAttributes.from_stat(os.lstat(os.path.join(self.resolve(path), name)))
                attr.filename = name; result.append(attr)
            return result
        except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
    def stat(self, path):
        try: return paramiko.SFTPAttributes.from_stat(os.lstat(self.resolve(path)))
        except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
    lstat = stat
    def open(self, path, flags, attr):
        try:
            fd = os.open(self.resolve(path), flags, attr.st_mode or 0o600)
            mode = 'r+b' if flags & os.O_RDWR else ('wb' if flags & os.O_WRONLY else 'rb')
            stream = os.fdopen(fd, mode); handle = paramiko.SFTPHandle(flags)
            if flags & (os.O_WRONLY | os.O_RDWR): handle.writefile = stream
            if not flags & os.O_WRONLY: handle.readfile = stream
            return handle
        except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
    def operation(self, fn, *args):
        try: fn(*args); return paramiko.SFTP_OK
        except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
    def remove(self, path): return self.operation(os.unlink, self.resolve(path))
    def rmdir(self, path): return self.operation(os.rmdir, self.resolve(path))
    def mkdir(self, path, attr): return self.operation(os.mkdir, self.resolve(path), attr.st_mode or 0o755)
    def rename(self, old, new): return self.operation(os.rename, self.resolve(old), self.resolve(new))
    def chattr(self, path, attr):
        if attr.st_mode is not None: return self.operation(os.chmod, self.resolve(path), attr.st_mode)
        return paramiko.SFTP_OK

def relay(channel, destination):
    peer = socket.create_connection(destination)
    relay_peers(channel, peer)

def relay_peers(channel, peer):
    def pump(source, target):
        try:
            while True:
                data = source.recv(32768)
                if not data: break
                target.sendall(data)
        except Exception: pass
        finally:
            channel.close(); peer.close()
    threading.Thread(target=pump, args=(channel, peer), daemon=True).start()
    pump(peer, channel)

def client(sock):
    transport = paramiko.Transport(sock); transport.add_server_key(key)
    transport.set_subsystem_handler('sftp', paramiko.SFTPServer, SFTP)
    try:
        server = Server(); server.transport = transport
        transport.start_server(server=server)
        channels = []
        while transport.is_active():
            channel = transport.accept(1)
            if channel is not None:
                channels.append(channel)
                if channel.chanid in server.destinations: threading.Thread(target=relay, args=(channel, server.destinations[channel.chanid]), daemon=True).start()
            channels = [c for c in channels if not c.closed]
    except Exception: pass

echo_listener = socket.socket(); echo_listener.bind(("127.0.0.1", 0)); echo_listener.listen(10)
def echo(sock):
    try:
        while True:
            data = sock.recv(32768)
            if not data: break
            sock.sendall(data)
    except Exception: pass
    finally: sock.close()
def accept_echo():
    while True:
        sock, _ = echo_listener.accept(); threading.Thread(target=echo, args=(sock,), daemon=True).start()
threading.Thread(target=accept_echo, daemon=True).start()

listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(10)
info = {'echoPort': echo_listener.getsockname()[1], 'port': listener.getsockname()[1], 'hostKey': key.get_name() + ' ' + key.get_base64(), 'root': root, 'clientKey': keypath}
with open(sys.argv[1], 'w') as f: json.dump(info, f)
print(json.dumps(info), flush=True)
while True:
    sock, _ = listener.accept(); threading.Thread(target=client, args=(sock,), daemon=True).start()
