#!/usr/bin/env python3
"""An isolated loopback OpenSSH fixture. No user SSH configuration or system daemon changes."""
import getpass, json, os, pathlib, socket, subprocess, sys, tempfile, signal
root = pathlib.Path(tempfile.mkdtemp(prefix='axon-openssh-', dir='/private/tmp'))
os.chmod(root, 0o700)
processes = []
def command(*args): subprocess.run(args, check=True, stdout=subprocess.DEVNULL)
def key(name, kind):
    path = root / name
    command('/usr/bin/ssh-keygen', '-q', '-t', kind, '-N', '', '-f', str(path))
    return str(path)
host = key('host', 'rsa'); rsa = key('client-rsa', 'rsa'); ed = key('client-ed', 'ed25519'); ca = key('ca', 'ed25519'); wrong_ca = key('wrong-ca', 'ed25519')
command('/usr/bin/ssh-keygen', '-q', '-s', ca, '-I', 'axon-host', '-h', '-n', '127.0.0.1', '-V', '-1m:+1h', host + '.pub')
expired = root / 'expired.pub'; expired.write_text(pathlib.Path(ed + '.pub').read_text())
command('/usr/bin/ssh-keygen', '-q', '-s', ca, '-I', 'expired', '-n', getpass.getuser(), '-V', '-2h:-1h', str(expired))
for path in [rsa, ed]: command('/usr/bin/ssh-keygen', '-q', '-s', ca, '-I', 'axon-test', '-n', getpass.getuser(), '-V', '-1m:+1h', path + '.pub')
(root / 'authorized_keys').write_text(pathlib.Path(rsa + '.pub').read_text() + pathlib.Path(ed + '.pub').read_text())
info = {'root': str(root), 'username': getpass.getuser(), 'rsaKey': rsa, 'edKey': ed, 'ca': ca + '.pub', 'wrongCA': wrong_ca + '.pub', 'expiredCertificate': str(root / 'expired-cert.pub'), 'hostKey': ' '.join(pathlib.Path(host + '.pub').read_text().split()[:2])}
try:
    for algorithm in ['512', '256', 'cert']:
        host_algorithm = 'rsa-sha2-512-cert-v01@openssh.com' if algorithm == 'cert' else 'rsa-sha2-' + algorithm
        user_algorithm = '512' if algorithm == 'cert' else algorithm
        certificate_line = 'HostCertificate ' + host + '-cert.pub' if algorithm == 'cert' else ''
        with socket.socket() as sock: sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
        config = root / ('sshd-' + algorithm + '.conf')
        config.write_text(f'''ListenAddress 127.0.0.1
Port {port}
HostKey {host}
HostKeyAlgorithms {host_algorithm}
{certificate_line}
PubkeyAcceptedAlgorithms rsa-sha2-{user_algorithm},rsa-sha2-{user_algorithm}-cert-v01@openssh.com,ssh-ed25519,ssh-ed25519-cert-v01@openssh.com
AuthorizedKeysFile {root}/authorized_keys
TrustedUserCAKeys {ca}.pub
PidFile {root}/pid-{algorithm}
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AllowUsers {getpass.getuser()}
AllowAgentForwarding yes
Subsystem sftp internal-sftp
LogLevel VERBOSE
''')
        log = open(root / ('sshd-' + algorithm + '.log'), 'wb')
        process = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(config)], stdout=log, stderr=log)
        processes.append(process); info['port' + algorithm] = port
    pathlib.Path(sys.argv[1]).write_text(json.dumps(info)); os.chmod(sys.argv[1], 0o600)
    print('Loopback OpenSSH fixture ready', flush=True)
    def stop(*_): raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, stop)
    while True: signal.pause()
except KeyboardInterrupt: pass
finally:
    for process in processes:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill()
