"""iPad の MicSender から届く UDP 音声を再生する受信側スクリプト。

VB-CABLE や VoiceMeeter の入力デバイスへ出力すれば、Discord や Zoom から
「マイク」として選べるようになる。

    python receiver.py --list-devices
    python receiver.py --device "CABLE Input"
"""

import argparse
import queue
import socket
import struct
import sys
import threading
import time

import numpy as np
import sounddevice as sd

MAGIC = b"IMIC"
VERSION = 1
HEADER_FORMAT = "<4sBBHII"
HEADER_SIZE = struct.calcsize(HEADER_FORMAT)

assert HEADER_SIZE == 16, HEADER_SIZE


class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.packets = 0
        self.lost = 0
        self.underruns = 0
        self.expected_seq = None

    def on_packet(self, seq):
        with self.lock:
            self.packets += 1
            if self.expected_seq is not None and seq != self.expected_seq:
                gap = (seq - self.expected_seq) & 0xFFFFFFFF
                # 大きすぎる差分は送信側の再起動とみなし、ロスに数えない。
                if gap < 1000:
                    self.lost += gap
            self.expected_seq = (seq + 1) & 0xFFFFFFFF

    def on_underrun(self):
        with self.lock:
            self.underruns += 1

    def snapshot(self):
        with self.lock:
            return self.packets, self.lost, self.underruns


def list_devices():
    print(sd.query_devices())


def resolve_device(name):
    if name is None:
        return None
    try:
        return int(name)
    except ValueError:
        pass
    lowered = name.lower()
    for index, device in enumerate(sd.query_devices()):
        if device["max_output_channels"] > 0 and lowered in device["name"].lower():
            return index
    raise SystemExit("出力デバイスが見つかりません: " + name)


def receive_loop(sock, buffer, stats, expected_frames, stop_event, gain):
    while not stop_event.is_set():
        try:
            data, _ = sock.recvfrom(4096)
        except socket.timeout:
            continue
        except OSError:
            break

        if len(data) < HEADER_SIZE:
            continue
        magic, version, channels, frames, sample_rate, seq = struct.unpack(
            HEADER_FORMAT, data[:HEADER_SIZE]
        )
        if magic != MAGIC or version != VERSION:
            continue

        payload = data[HEADER_SIZE:]
        if len(payload) != frames * channels * 2:
            continue

        stats.on_packet(seq)
        block = np.frombuffer(payload, dtype="<i2").reshape(-1, channels)
        if block.shape[0] != expected_frames:
            continue

        if gain != 1.0:
            block = np.clip(block * gain, -32768, 32767).astype("<i2")

        try:
            buffer.put_nowait(block)
        except queue.Full:
            # 遅れている分を捨てて追いつく。
            try:
                buffer.get_nowait()
                buffer.put_nowait(block)
            except queue.Empty:
                pass


def main():
    parser = argparse.ArgumentParser(description="MicSender UDP receiver")
    parser.add_argument("--port", type=int, default=50005, help="待ち受けポート")
    parser.add_argument("--bind", default="0.0.0.0", help="待ち受けアドレス")
    parser.add_argument("--device", default=None, help="出力デバイス名の一部またはインデックス")
    parser.add_argument("--samplerate", type=int, default=48000)
    parser.add_argument("--channels", type=int, default=1)
    parser.add_argument("--frames", type=int, default=480, help="1 パケットあたりのサンプル数")
    parser.add_argument(
        "--jitter",
        type=int,
        default=4,
        help="再生開始までに貯めるパケット数 (1 パケット = 10 ms)",
    )
    parser.add_argument(
        "--gain",
        type=float,
        default=1.0,
        help="再生前に掛ける倍率。2.0 で約 +6 dB。超えた分はクリップする",
    )
    parser.add_argument("--list-devices", action="store_true")
    args = parser.parse_args()

    if args.list_devices:
        list_devices()
        return

    device = resolve_device(args.device)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
    sock.settimeout(0.5)
    sock.bind((args.bind, args.port))

    # ジッタバッファ。上限は 200 ms 相当。
    buffer = queue.Queue(maxsize=max(args.jitter * 4, 20))
    stats = Stats()
    stop_event = threading.Event()
    primed = threading.Event()
    silence = np.zeros((args.frames, args.channels), dtype="<i2")

    def callback(outdata, frames, time_info, status):
        if not primed.is_set():
            if buffer.qsize() >= args.jitter:
                primed.set()
            else:
                outdata[:] = silence[:frames]
                return
        try:
            block = buffer.get_nowait()
        except queue.Empty:
            stats.on_underrun()
            primed.clear()
            outdata[:] = silence[:frames]
            return
        outdata[:] = block[:frames]

    receiver = threading.Thread(
        target=receive_loop,
        args=(sock, buffer, stats, args.frames, stop_event, args.gain),
        daemon=True,
    )
    receiver.start()

    stream = sd.OutputStream(
        samplerate=args.samplerate,
        channels=args.channels,
        dtype="int16",
        blocksize=args.frames,
        device=device,
        latency="low",
        callback=callback,
    )

    name = sd.query_devices(device if device is not None else sd.default.device[1])["name"]
    print("待ち受け: {}:{}".format(args.bind, args.port))
    print("出力先  : {}".format(name))
    print("形式    : {} Hz / {} ch / int16 / {} サンプルブロック".format(
        args.samplerate, args.channels, args.frames))
    if args.gain != 1.0:
        print("ゲイン  : {:.2f} 倍".format(args.gain))
    print("Ctrl+C で終了")

    try:
        with stream:
            while True:
                time.sleep(1.0)
                packets, lost, underruns = stats.snapshot()
                sys.stdout.write(
                    "\rpackets={:<10} lost={:<8} underrun={:<6} buffer={:<3}".format(
                        packets, lost, underruns, buffer.qsize()
                    )
                )
                sys.stdout.flush()
    except KeyboardInterrupt:
        print()
    finally:
        stop_event.set()
        sock.close()


if __name__ == "__main__":
    main()
