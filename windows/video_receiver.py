"""iPad の MicSender から届くカメラ映像を受信するスクリプト。

プレビューウィンドウに表示し、--virtualcam を付けると OBS Virtual Camera に流す。
Zoom や Discord のカメラ選択で「OBS Virtual Camera」を選べば Web カメラとして使える。

    python video_receiver.py
    python video_receiver.py --virtualcam
    python video_receiver.py --virtualcam --no-preview
"""

import argparse
import socket
import struct
import sys
import threading
import time

import cv2
import numpy as np

from netinfo import print_addresses

MAGIC = b"IVID"
VERSION = 1
HEADER_FORMAT = "<4sBBHHHII"
HEADER_SIZE = struct.calcsize(HEADER_FORMAT)
FLAG_FRONT_CAMERA = 0x01
MAX_FRAME_BYTES = 16 * 1024 * 1024
WINDOW_TITLE = "MicSender Camera"

assert HEADER_SIZE == 20, HEADER_SIZE


class LatestFrame:
    """受信スレッドと表示ループの間で、最新の 1 フレームだけを受け渡す。"""

    def __init__(self):
        self.condition = threading.Condition()
        self.frame = None
        self.flags = 0
        self.sequence = 0

    def put(self, frame, flags):
        with self.condition:
            self.frame = frame
            self.flags = flags
            self.sequence += 1
            self.condition.notify_all()

    def wait_newer(self, last_sequence, timeout):
        with self.condition:
            if self.sequence == last_sequence:
                self.condition.wait(timeout)
            return self.frame, self.flags, self.sequence


class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.frames = 0
        self.bytes = 0
        self.dropped = 0
        self.connections = 0
        self.size = None

    def on_frame(self, nbytes, width, height):
        with self.lock:
            self.frames += 1
            self.bytes += nbytes
            self.size = (width, height)

    def on_drop(self):
        with self.lock:
            self.dropped += 1

    def on_connect(self):
        with self.lock:
            self.connections += 1

    def snapshot(self):
        with self.lock:
            return self.frames, self.bytes, self.dropped, self.connections, self.size


def recv_exact(conn, size):
    buffer = bytearray(size)
    view = memoryview(buffer)
    received = 0
    while received < size:
        n = conn.recv_into(view[received:], size - received)
        if n == 0:
            raise ConnectionError("closed")
        received += n
    return buffer


def handle_client(conn, address, latest, stats):
    print("\n接続: {}:{}".format(*address))
    try:
        while True:
            header = recv_exact(conn, HEADER_SIZE)
            magic, version, flags, width, height, _, length, _ = struct.unpack(HEADER_FORMAT, header)
            if magic != MAGIC or version != VERSION or length > MAX_FRAME_BYTES:
                print("\n不正なヘッダを受信したので切断します")
                break

            payload = recv_exact(conn, length)
            frame = cv2.imdecode(np.frombuffer(payload, dtype=np.uint8), cv2.IMREAD_COLOR)
            if frame is None:
                stats.on_drop()
                continue

            stats.on_frame(length, frame.shape[1], frame.shape[0])
            latest.put(frame, flags)
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass
        print("\n切断: {}:{}".format(*address))


def accept_loop(server, latest, stats, stop_event):
    current = None
    while not stop_event.is_set():
        try:
            conn, address = server.accept()
        except socket.timeout:
            continue
        except OSError:
            break

        # iPad 側は切れると繋ぎ直してくる。古い接続が半開きのまま残っていても新しい方を優先する。
        if current is not None:
            # Windows では shutdown だけだと別スレッドの recv が戻らないので close まで行う。
            for close in (lambda: current.shutdown(socket.SHUT_RDWR), current.close):
                try:
                    close()
                except OSError:
                    pass

        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        conn.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        current = conn
        stats.on_connect()
        threading.Thread(
            target=handle_client, args=(conn, address, latest, stats), daemon=True
        ).start()


def fit_frame(frame, width, height):
    """アスペクト比を保ったまま黒帯を付けて指定サイズに収める。"""
    frame_height, frame_width = frame.shape[:2]
    if (frame_width, frame_height) == (width, height):
        return frame

    scale = min(width / frame_width, height / frame_height)
    new_width = max(1, int(round(frame_width * scale)))
    new_height = max(1, int(round(frame_height * scale)))
    interpolation = cv2.INTER_AREA if scale < 1 else cv2.INTER_LINEAR
    resized = cv2.resize(frame, (new_width, new_height), interpolation=interpolation)

    canvas = np.zeros((height, width, 3), dtype=np.uint8)
    x = (width - new_width) // 2
    y = (height - new_height) // 2
    canvas[y:y + new_height, x:x + new_width] = resized
    return canvas


def open_virtual_camera(width, height, fps):
    try:
        import pyvirtualcam
    except ImportError:
        raise SystemExit("pyvirtualcam が入っていません: pip install pyvirtualcam")

    try:
        camera = pyvirtualcam.Camera(
            width=width, height=height, fps=fps, fmt=pyvirtualcam.PixelFormat.BGR
        )
    except RuntimeError as error:
        raise SystemExit(
            "仮想カメラを開けませんでした。OBS Studio をインストールし、"
            "一度「仮想カメラ開始」を押して登録してください。\n詳細: {}".format(error)
        )
    camera.send(np.zeros((height, width, 3), dtype=np.uint8))
    return camera


def main():
    parser = argparse.ArgumentParser(description="MicSender video receiver")
    parser.add_argument("--port", type=int, default=50006, help="待ち受けポート (TCP)")
    parser.add_argument("--bind", default="0.0.0.0", help="待ち受けアドレス")
    parser.add_argument("--no-preview", action="store_true", help="プレビューウィンドウを出さない")
    parser.add_argument("--virtualcam", action="store_true", help="OBS Virtual Camera に出力する")
    parser.add_argument("--width", type=int, default=1280, help="仮想カメラの幅")
    parser.add_argument("--height", type=int, default=720, help="仮想カメラの高さ")
    parser.add_argument("--fps", type=int, default=30, help="仮想カメラのフレームレート")
    args = parser.parse_args()

    # 720p 程度のデコードとリサイズなら数スレッドで足りる。配信やゲームと CPU を取り合わないよう絞る。
    cv2.setNumThreads(2)

    camera = open_virtual_camera(args.width, args.height, args.fps) if args.virtualcam else None

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.bind, args.port))
    server.listen(2)
    server.settimeout(0.5)

    latest = LatestFrame()
    stats = Stats()
    stop_event = threading.Event()
    threading.Thread(
        target=accept_loop, args=(server, latest, stats, stop_event), daemon=True
    ).start()

    print_addresses()
    print("待ち受け  : {}:{} (TCP)".format(args.bind, args.port))
    if camera is not None:
        print("仮想カメラ: {} ({}x{} @ {} fps)".format(camera.device, args.width, args.height, args.fps))
    if args.no_preview:
        print("プレビュー: なし")
    elif camera is not None:
        print("プレビュー: あり (ウィンドウを閉じても仮想カメラへの出力は続く。q か Esc で終了)")
    else:
        print("プレビュー: あり (ウィンドウを閉じるか q / Esc で終了)")
    print("Ctrl+C で終了")

    preview = not args.no_preview
    last_sequence = 0
    window_shown = False
    report_at = time.monotonic() + 1.0
    last_frames = 0
    last_bytes = 0

    try:
        while True:
            frame, flags, sequence = latest.wait_newer(last_sequence, timeout=0.02)
            if sequence != last_sequence and frame is not None:
                last_sequence = sequence
                if camera is not None:
                    camera.send(fit_frame(frame, args.width, args.height))
                if preview:
                    cv2.imshow(WINDOW_TITLE, frame)
                    window_shown = True

            if preview:
                key = cv2.waitKey(1) & 0xFF
                if key in (27, ord("q")):
                    break
                if window_shown and cv2.getWindowProperty(WINDOW_TITLE, cv2.WND_PROP_VISIBLE) < 1:
                    if camera is None:
                        break
                    # 仮想カメラを使っているときは、プレビューだけ閉じて出力を続ける。
                    preview = False
                    cv2.destroyAllWindows()
                    print("\nプレビューを閉じました。仮想カメラへの出力は続けます (Ctrl+C で終了)")

            now = time.monotonic()
            if now >= report_at:
                frames, total_bytes, dropped, connections, size = stats.snapshot()
                fps = frames - last_frames
                kbps = (total_bytes - last_bytes) * 8 / 1000
                last_frames, last_bytes = frames, total_bytes
                report_at = now + 1.0
                size_text = "{}x{}".format(*size) if size else "-"
                camera_text = "内" if flags & FLAG_FRONT_CAMERA else "外"
                sys.stdout.write(
                    "\rframes={:<8} fps={:<3} size={:<10} cam={} {:>7.0f} kbps dropped={} conn={}   ".format(
                        frames, fps, size_text, camera_text if size else "-", kbps, dropped, connections
                    )
                )
                sys.stdout.flush()
    except KeyboardInterrupt:
        pass
    finally:
        print()
        stop_event.set()
        server.close()
        if camera is not None:
            camera.close()
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
