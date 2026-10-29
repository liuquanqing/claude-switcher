"""Minimal synthetic packet peer, NOT a production TCP stack or proxy.
Used only by leased_utun_clients_probe on a disposable macOS runner.
"""
import json, os, socket, struct, time


def checksum(data):
    if len(data) % 2:
        data += b'\0'
    total = sum(struct.unpack('!%dH' % (len(data) // 2), data))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    return (~total) & 65535


def sse(event, data):
    return ('event: ' + event + '\ndata: ' + json.dumps(data) + '\n\n').encode()


class Peer:
    def __init__(self, fd, permitted):
        self.fd, self.permitted = fd, permitted
        self.flows = {}
        self.http, self.syn, self.tls, self.sse = {}, {}, {}, {}
        self.tcp_tokens, self.udp_tokens = [], []
        self.pushes, self.denied_pushes = 0, 0

    def snapshot(self):
        return dict(http=dict(self.http), syn=dict(self.syn), tls=dict(self.tls), sse=dict(self.sse),
                    tcpTokens=list(self.tcp_tokens), udpTokens=list(self.udp_tokens),
                    pushes=self.pushes, deniedPushes=self.denied_pushes)

    def packet(self, version, src, dst, proto, body):
        if not self.permitted():
            return
        if version == 6:
            header = struct.pack('!IHBB', 6 << 28, len(body), proto, 64) + src + dst
        else:
            header = struct.pack('!BBHHHBBH', 0x45, 0, len(body) + 20, 0, 0, 64, proto, 0) + src + dst
            header = header[:10] + struct.pack('!H', checksum(header)) + header[12:]
        os.write(self.fd, struct.pack('!I', socket.AF_INET if version == 4 else socket.AF_INET6) + header + body)

    def tcp(self, key, state, flags, payload=b''):
        version, src, dst, sport, dport = key
        segment = struct.pack('!HHIIBBHHH', dport, sport, state['server'], state['next'],
                              5 << 4, flags, 65535, 0, 0) + payload
        pseudo = dst + src + (struct.pack('!I3xB', len(segment), 6) if version == 6 else struct.pack('!BBH', 0, 6, len(segment)))
        segment = segment[:16] + struct.pack('!H', checksum(pseudo + segment)) + segment[18:]
        self.packet(version, dst, src, 6, segment)
        state['server'] = (state['server'] + len(payload) + bool(flags & 2) + bool(flags & 1)) & 0xffffffff

    def consume(self, raw):
        if len(raw) < 24:
            return
        p = raw[4:]
        version = p[0] >> 4
        if version == 4:
            offset, proto, src, dst = (p[0] & 15) * 4, p[9], p[12:16], p[16:20]
        elif version == 6:
            offset, proto, src, dst = 40, p[6], p[8:24], p[24:40]
        else:
            return
        data = p[offset:]
        if proto == 17 and len(data) >= 8:
            sport, dport, size, _ = struct.unpack('!HHHH', data[:8])
            if dport != 29300 or not self.permitted():
                return
            payload = data[8:size]
            self.udp_tokens.append(payload.decode(errors='replace'))
            reply = struct.pack('!HHHH', dport, sport, size, 0) + payload
            if version == 6:
                value = checksum(dst + src + struct.pack('!I3xB', len(reply), 17) + reply) or 65535
                reply = reply[:6] + struct.pack('!H', value) + reply[8:]
            self.packet(version, dst, src, 17, reply)
            return
        if proto != 6 or len(data) < 20:
            return
        sport, dport, seq, ack, off, flags, *_ = struct.unpack('!HHIIBBHHH', data[:20])
        if dport not in (29300, 29301, 29302):
            return
        counter = str(version) + ':' + str(dport)
        if flags & 2:
            self.syn[counter] = self.syn.get(counter, 0) + 1
        if not self.permitted():
            return
        key = version, src, dst, sport, dport
        if flags & 2:
            state = dict(next=(seq + 1) & 0xffffffff, server=1000, buffer=b'', mode='header')
            self.flows[key] = state
            self.tcp(key, state, 0x12)
            return
        state = self.flows.get(key)
        if state is None:
            return
        if flags & 4:
            self.flows.pop(key, None)
            return
        payload = data[(off >> 4) * 4:]
        if not payload:
            return
        if seq != state['next']:
            self.tcp(key, state, 0x10)
            return
        state['next'] = (seq + len(payload)) & 0xffffffff
        if dport == 29302:
            self.tcp_tokens.append(payload.decode(errors='replace'))
            self.tcp(key, state, 0x18, payload)
            return
        self.tcp(key, state, 0x10)
        if state['mode'] == 'tls':
            self.tls[counter] = self.tls.get(counter, 0) + len(payload)
            return
        if state['mode'] != 'header':
            return
        state['buffer'] += payload
        if b'\r\n\r\n' not in state['buffer']:
            return
        header, body = state['buffer'].split(b'\r\n\r\n', 1)
        length = 0
        for line in header.split(b'\r\n')[1:]:
            if line.lower().startswith(b'content-length:'):
                length = int(line.split(b':', 1)[1])
        if len(body) < length or not self.permitted():
            return
        self.http[counter] = self.http.get(counter, 0) + 1
        if dport == 29301:
            state['mode'] = 'tls'
            self.tcp(key, state, 0x18, b'HTTP/1.1 200 Connection Established\r\n\r\n')
        elif b'/count_tokens' in header.split(b'\r\n', 1)[0]:
            reply = b'{"input_tokens":1}'
            self.tcp(key, state, 0x19, b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ' + str(len(reply)).encode() + b'\r\n\r\n' + reply)
            state['mode'] = 'closed'
        else:
            state['mode'] = 'sse'
            self.sse[counter] = self.sse.get(counter, 0) + 1
            msg = dict(id='msg_fixture', type='message', role='assistant', model='claude-sonnet-4-6', content=[],
                       stop_reason=None, stop_sequence=None, usage=dict(input_tokens=1, output_tokens=0))
            reply = b'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n'
            reply += sse('message_start', dict(type='message_start', message=msg))
            reply += sse('content_block_start', dict(type='content_block_start', index=0, content_block=dict(type='text', text='')))
            reply += sse('content_block_delta', dict(type='content_block_delta', index=0, delta=dict(type='text_delta', text='fixture-start')))
            self.tcp(key, state, 0x18, reply)

    def push(self):
        if not self.permitted():
            self.denied_pushes += 1
            return
        for key, state in list(self.flows.items()):
            if state['mode'] == 'sse':
                reply = sse('content_block_delta', dict(type='content_block_delta', index=0,
                            delta=dict(type='text_delta', text='fixture-push')))
                self.tcp(key, state, 0x18, reply)
                self.pushes += 1
