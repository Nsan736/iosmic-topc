"""iPad の MicSender から届くカメラ映像を受信するスクリプト。

プレビューウィンドウに表示し、--virtualcam を付けると OBS Virtual Camera に流す。
Zoom や Discord のカメラ選択で「OBS Virtual Camera」を選べば Web カメラとして使える。

    python video_receiver.py
    python video_receiver.py --virtualcam
    python video_receiver.py --virtualcam --no-preview

止まったときの調査用に、同じフォルダの video_receiver.log へ経過を書き出す。
"""

import argparse
import datetime
import os
import socket
import struct
import sys
import threading
import time
import traceback

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
LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "video_receiver.log")

# メイン処理がこの秒数以上止まったら、どこで止まっているかを書き出す。
MAIN_STALL_SECONDS = 3
# iPad からのデータがこの秒数以上届かなければ知らせる。
DATA_STALL_SECONDS = 5

assert HEADER_SIZE == 20, HEADER_SIZE


class Log:
    """ターミナルとログファイルの両方に書く。ターミナルが詰まっても先にファイルへ残す。"""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        with open(self.path, "w", encoding="utf-8") as f:
            f.write("video_receiver 開始 {}\n".format(datetime.datetime.now().isoformat(timespec="seconds")))

    def write(self, message, echo=True):
        stamp = datetime.datetime.now().strftime("%H:%M:%S")
        with self.lock:
            with open(self.path, "a", encoding="utf-8") as f:
                for line in message.splitlines() or [""]:
                    f.write("{} {}\n".format(stamp, line))
        if echo:
            print("\n" + message, flush=True)


class LatestFrame:
    """受信スレッドとメイン処理の間で、最新の 1 フレーム分の JPEG だけを受け渡す。"""

    def __init__(self):
        self.condition = threading.Condition()
        self.payload = None
        self.flags = 0
        self.sequence = 0

    def put(self, payload, flags):
        with self.condition:
            self.payload = payload
            self.flags = flags
            self.sequence += 1
            self.condition.notify_all()

    def wait_newer(self, last_sequence, timeout):
        with self.condition:
            if self.sequence == last_sequence:
                self.condition.wait(timeout)
            return self.payload, self.flags, self.sequence


class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.frames = 0
        self.bytes = 0
        self.dropped = 0
        self.connections = 0
        self.size = None
        # 最後に iPad からデータが届いた時刻。接続がなければ None。
        self.last_data_at = None
        self.handler_ident = None

    def begin_connection(self):
        with self.lock:
            self.last_data_at = time.monotonic()
            self.handler_ident = threading.get_ident()

    def end_connection(self):
        with self.lock:
            if self.handler_ident == threading.get_ident():
                self.last_data_at = None
                self.handler_ident = None

    def on_data(self):
        with self.lock:
            self.last_data_at = time.monotonic()

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

    def last_data(self):
        with self.lock:
            return self.last_data_at

    def snapshot(self):
        with self.lock:
            return self.frames, self.bytes, self.dropped, self.connections, self.size


class Heartbeat:
    """メイン処理が今どの段階にいて、最後にいつ進んだかを記録する。"""

    def __init__(self):
        self.lock = threading.Lock()
        self.at = time.monotonic()
        self.stage = "開始"
        self.ident = threading.get_ident()

    def beat(self, stage):
        with self.lock:
            self.at = time.monotonic()
            self.stage = stage

    def read(self):
        with self.lock:
            return self.at, self.stage


def recv_exact(conn, size, stats):
    buffer = bytearray(size)
    view = memoryview(buffer)
    received = 0
    while received < size:
        n = conn.recv_into(view[received:], size - received)
        if n == 0:
            raise ConnectionError("closed")
        received += n
        stats.on_data()
    return buffer


def handle_client(conn, address, latest, stats, log):
    # 受信スレッドは受け取るだけにし、OpenCV には触れない。
    # OpenCV を複数のスレッドから同時に呼ぶと内部で固まることがあるため、デコードはメイン処理に任せる。
    log.write("接続: {}:{}".format(*address))
    stats.begin_connection()
    try:
        while True:
            header = recv_exact(conn, HEADER_SIZE, stats)
            magic, version, flags, width, height, _, length, _ = struct.unpack(HEADER_FORMAT, header)
            if magic != MAGIC or version != VERSION or length > MAX_FRAME_BYTES:
                log.write("不正なヘッダを受信したので切断します")
                break

            payload = recv_exact(conn, length, stats)
            stats.on_frame(length, width, height)
            latest.put(bytes(payload), flags)
    except (ConnectionError, OSError):
        pass
    finally:
        stats.end_connection()
        try:
            conn.close()
        except OSError:
            pass
        log.write("切断: {}:{}".format(*address))


def accept_loop(server, latest, stats, log, stop_event):
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
            target=handle_client, args=(conn, address, latest, stats, log), daemon=True
        ).start()


def monitor_loop(heartbeat, stats, log, stop_event):
    """メイン処理とは別のスレッドで、止まっている箇所がないかを 1 秒ごとに調べる。"""
    main_stalled = False
    data_stalled = False
    while not stop_event.wait(1.0):
        now = time.monotonic()

        beat_at, stage = heartbeat.read()
        if now - beat_at > MAIN_STALL_SECONDS:
            if not main_stalled:
                main_stalled = True
                frame = sys._current_frames().get(heartbeat.ident)
                stack = "".join(traceback.format_stack(frame)).rstrip() if frame is not None else "(取得できず)"
                log.write(
                    "[注意] PC の表示処理が {:.0f} 秒止まっています。止まっている処理: {}\n"
                    "       iPad からの受信は続いています。この表示と {} を開発者に伝えてください。\n{}".format(
                        now - beat_at, stage, LOG_PATH, stack
                    )
                )
        elif main_stalled:
            main_stalled = False
            log.write("PC の表示処理が再開しました")

        last_data_at = stats.last_data()
        if last_data_at is not None and now - last_data_at > DATA_STALL_SECONDS:
            if not data_stalled:
                data_stalled = True
                log.write(
                    "[注意] iPad から {:.0f} 秒データが届いていません。\n"
                    "       PC はデータを待っているだけです。iPad 側が送信を止めているか、Wi-Fi が途切れています。".format(
                        now - last_data_at
                    )
                )
        elif data_stalled:
            data_stalled = False
            log.write("iPad からのデータが再開しました")


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

    # OpenCV 内部のスレッドプールを使わない。720p 程度なら 1 スレッドで十分間に合い、
    # 複数スレッドからの呼び出しで固まる経路もなくなる。
    cv2.setNumThreads(0)

    log = Log(LOG_PATH)
    camera = open_virtual_camera(args.width, args.height, args.fps) if args.virtualcam else None

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.bind, args.port))
    server.listen(2)
    server.settimeout(0.5)

    latest = LatestFrame()
    stats = Stats()
    heartbeat = Heartbeat()
    stop_event = threading.Event()
    threading.Thread(
        target=accept_loop, args=(server, latest, stats, log, stop_event), daemon=True
    ).start()
    threading.Thread(
        target=monitor_loop, args=(heartbeat, stats, log, stop_event), daemon=True
    ).start()

    print_addresses()
    print("待ち受け  : {}:{} (TCP)".format(args.bind, args.port))
    if camera is not None:
        print("仮想カメラ: {} ({}x{} @ {} fps)".format(camera.device, args.width, args.height, args.fps))
    if args.no_preview:
        print("プレビュー: なし")
    else:
        print("プレビュー: あり (ウィンドウを閉じても受信は続く。q / Esc か Ctrl+C で終了)")
    print("ログ      : {}".format(LOG_PATH))
    print("Ctrl+C で終了")

    preview = not args.no_preview
    last_sequence = 0
    window_shown = False
    report_at = time.monotonic() + 1.0
    last_frames = 0
    last_bytes = 0
    flags = 0

    try:
        while True:
            heartbeat.beat("新しいフレーム待ち")
            payload, flags, sequence = latest.wait_newer(last_sequence, timeout=0.02)
            if sequence != last_sequence and payload is not None:
                last_sequence = sequence

                heartbeat.beat("JPEG デコード (cv2.imdecode)")
                frame = cv2.imdecode(np.frombuffer(payload, dtype=np.uint8), cv2.IMREAD_COLOR)
                if frame is None:
                    stats.on_drop()
                else:
                    if camera is not None:
                        heartbeat.beat("仮想カメラ用の縮小 (cv2.resize)")
                        output = fit_frame(frame, args.width, args.height)
                        heartbeat.beat("仮想カメラへ出力 (pyvirtualcam)")
                        camera.send(output)
                    if preview:
                        heartbeat.beat("プレビュー表示 (cv2.imshow)")
                        cv2.imshow(WINDOW_TITLE, frame)
                        window_shown = True

            if preview:
                heartbeat.beat("ウィンドウ処理 (cv2.waitKey)")
                key = cv2.waitKey(1) & 0xFF
                if key in (27, ord("q")):
                    break
                heartbeat.beat("ウィンドウ状態の確認 (cv2.getWindowProperty)")
                if window_shown and cv2.getWindowProperty(WINDOW_TITLE, cv2.WND_PROP_VISIBLE) < 1:
                    # ここで終了すると iPad 側の接続が切れるので、プレビューだけ閉じて受信は続ける。
                    preview = False
                    cv2.destroyAllWindows()
                    log.write("プレビューを閉じました。受信は続けます (終了は Ctrl+C)")

            now = time.monotonic()
            if now >= report_at:
                frames, total_bytes, dropped, connections, size = stats.snapshot()
                fps = frames - last_frames
                kbps = (total_bytes - last_bytes) * 8 / 1000
                last_frames, last_bytes = frames, total_bytes
                report_at = now + 1.0
                size_text = "{}x{}".format(*size) if size else "-"
                camera_text = "内" if flags & FLAG_FRONT_CAMERA else "外"
                heartbeat.beat("状態表示の出力 (ターミナル)")
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
