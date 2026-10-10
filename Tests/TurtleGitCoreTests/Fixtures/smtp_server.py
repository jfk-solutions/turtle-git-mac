#!/usr/bin/env python3
"""One private loopback SMTP session; never connects to any external host."""
import base64
import json
from email.parser import BytesParser
from email import policy
from pathlib import Path
import socket
import ssl
import sys
root, mode = Path(sys.argv[1]), sys.argv[2]

def publish_json(name, value):
    # Readers use existence as readiness: expose only complete JSON files.
    destination = root / name
    temporary = destination.with_name(destination.name + '.tmp')
    temporary.write_text(json.dumps(value), encoding='utf-8')
    temporary.replace(destination)

server = socket.socket(); server.bind(('127.0.0.1', 0)); server.listen(1); server.settimeout(15)
publish_json('ready.json', {'port': server.getsockname()[1]})
state = {'mail': [], 'recipients': [], 'data': 0, 'accepted': 0, 'auth': 0, 'tls': False, 'ehlo': 0}
connection = None
try:
    connection, _ = server.accept(); connection.settimeout(10)
    if mode == 'stall':
        while connection.recv(1024): pass
    else:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        if mode == 'auth-required' or mode.startswith('implicit'):
            context.load_cert_chain(str(root / 'cert.pem'), str(root / 'key.pem'))
        if mode.startswith('implicit'):
            connection = context.wrap_socket(connection, server_side=True); state['tls'] = True
        stream = connection.makefile('rwb', buffering=0)
        def reply(value): stream.write(value.encode('ascii'))
        reply('220 localhost private SMTP fixture\r\n')
        authenticated = False
        while True:
            line = stream.readline()
            if not line: break
            command = line.decode('ascii', errors='replace').rstrip('\r\n')
            upper = command.upper()
            if upper.startswith(('EHLO ', 'HELO ')):
                state['ehlo'] += 1
                reply('250-localhost\r\n')
                if not state['tls'] and mode == 'auth-required': reply('250-STARTTLS\r\n')
                reply('250-AUTH PLAIN LOGIN\r\n250 SIZE 10000000\r\n')
            elif upper == 'STARTTLS':
                reply('220 Ready for TLS\r\n'); stream.close()
                connection = context.wrap_socket(connection, server_side=True); state['tls'] = True
                stream = connection.makefile('rwb', buffering=0)
            elif upper.startswith('AUTH PLAIN'):
                state['auth'] += 1
                parts = command.split(' ', 2)
                encoded = parts[2].encode() if len(parts) == 3 else None
                if encoded is None: reply('334 \r\n'); encoded = stream.readline().strip()
                try: fields = base64.b64decode(encoded).split(b'\0'); valid = fields[-2:] == [b'fixture-user', b'fixture-password']
                except Exception: valid = False
                authenticated = valid and mode != 'auth-reject'
                reply('235 Authentication successful\r\n' if authenticated else '535 Authentication rejected\r\n')
            elif upper == 'AUTH LOGIN':
                state['auth'] += 1
                reply('334 VXNlcm5hbWU6\r\n'); username = base64.b64decode(stream.readline().strip())
                reply('334 UGFzc3dvcmQ6\r\n'); password = base64.b64decode(stream.readline().strip())
                authenticated = username == b'fixture-user' and password == b'fixture-password' and mode != 'auth-reject'
                reply('235 Authentication successful\r\n' if authenticated else '535 Authentication rejected\r\n')
            elif upper.startswith('MAIL FROM:'):
                state['mail'].append(command)
                if mode in ('auth-required', 'implicit-auth') and not authenticated: reply('530 Authentication required\r\n')
                else: reply('250 Sender accepted\r\n')
            elif upper.startswith('RCPT TO:'):
                state['recipients'].append(command)
                reply('550 Recipient rejected\r\n' if mode == 'reject' and len(state['recipients']) == 2 else '250 Recipient accepted\r\n')
            elif upper == 'DATA':
                state['data'] += 1; reply('354 End with a dot\r\n'); body = bytearray()
                while True:
                    item = stream.readline()
                    if not item: raise EOFError()
                    if item == b'.\r\n': break
                    if item.startswith(b'..'): item = item[1:]
                    body.extend(item)
                (root / 'message.eml').write_bytes(body)
                message = BytesParser(policy=policy.default).parsebytes(bytes(body))
                parts = list(message.iter_parts()) if message.is_multipart() else [message]
                state['parts'] = [{'filename': part.get_filename(), 'payload': base64.b64encode(part.get_payload(decode=True)).decode('ascii')} for part in parts]
                if mode == 'drop-final': break
                state['accepted'] += 1; reply('250 Message accepted\r\n')
            elif upper == 'QUIT': reply('221 Bye\r\n'); break
            elif upper == 'RSET': reply('250 Reset\r\n')
            else: reply('500 Unsupported command\r\n')
except (OSError, ssl.SSLError, EOFError) as error:
    state['error_type'] = type(error).__name__
finally:
    if connection is not None: connection.close()
    server.close(); publish_json('result.json', state)
