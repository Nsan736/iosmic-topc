"""受信スクリプト共通: iPad のアプリに入力すべき PC の IP アドレスを調べる。"""

import socket


def lan_addresses():
    """既定ルートに使われるアドレスを先頭にして、ループバック以外の IPv4 を返す。"""
    primary = None
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            # UDP の connect はパケットを送らず、経路の決定だけを行う。
            probe.connect(("8.8.8.8", 80))
            primary = probe.getsockname()[0]
        finally:
            probe.close()
    except OSError:
        pass

    others = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            others.add(info[4][0])
    except OSError:
        pass

    addresses = [primary] if primary else []
    addresses += sorted(a for a in others if a != primary)
    return [a for a in addresses if not a.startswith(("127.", "169.254."))]


def print_addresses():
    addresses = lan_addresses()
    if not addresses:
        print("PC の IP  : 取得できませんでした (ipconfig で確認してください)")
        return
    print("PC の IP  : {}  <- iPad のアプリにはこれを入力".format(addresses[0]))
    for address in addresses[1:]:
        print("            {}  (仮想アダプタなど。通常は使わない)".format(address))
