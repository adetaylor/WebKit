from pywebsocket3 import handshake


def web_socket_do_extra_handshake(request):
    message = 'HTTP/1.1 101 Switching Protocols\r\n'
    message += 'Upgrade: websocket\r\n'
    message += 'Connection: Upgrade\r\n'
    message += 'Sec-WebSocket-Accept: XXXXthisiswrongXXXX\r\n'
    message += '\r\n'
    request.connection.write(message.encode())
    raise handshake.AbortedByUserException('Abort the connection') # Prevents pywebsocket from sending its own handshake message.


def web_socket_transfer_data(request):
    pass
