from dotenv import load_dotenv
from flask import Flask, Response, abort
from ftplib import FTP, all_errors, error_perm
from mimetypes import guess_type
from os import getenv

from prometheus_client import generate_latest, Gauge, CONTENT_TYPE_LATEST


load_dotenv()

FTP_HOST = getenv("FTP_HOST")
FTP_USER = getenv("FTP_USER")
FTP_PASSWD = getenv("FTP_PASSWD")
FTP_PATH = getenv("FTP_PATH")

BLOCK_SIZE = 64 * 1024

ACCEPTED_FILENAMES = [
    "Aseprite.AppImage",
    "aseprite-linux.zip",
    "aseprite-windows.zip",
    "aseprite-macos.zip"
]

DOWNLOADED_FILES_COUNTER = Gauge("aseprite_download_filename", "Counter of downloads by filename", ["filename"])

app = Flask(__name__)

@app.route("/")
def index_route():
    return abort(404)

@app.route("/metrics")
def metrics_route():
    return Response(
        generate_latest(),
        mimetype=CONTENT_TYPE_LATEST
    )

@app.route("/<filename>")
def serve_file(filename):
    if filename not in ACCEPTED_FILENAMES:
        return abort(403)

    fullpath = FTP_PATH + "/" + filename

    try:
        ftp = FTP(
            host=FTP_HOST,
            user=FTP_USER,
            passwd=FTP_PASSWD
        )
    except all_errors:
        return abort(502)

    try:
        ftp.voidcmd("TYPE I")
        size = ftp.size(fullpath)
        stream = ftp.transfercmd(f"RETR {fullpath}")
    except error_perm:
        ftp.close()
        return abort(404)
    except all_errors:
        ftp.close()
        return abort(502)

    # the session is kept open until the transfer is over
    def chunks():
        sent = 0

        try:
            while chunk := stream.recv(BLOCK_SIZE):
                sent = sent + len(chunk)
                yield chunk
        finally:
            stream.close()
            ftp.close()

        if size is not None and sent != size:
            raise OSError(
                f"truncated transfer: got {sent} bytes out of {size}"
            )
            
    DOWNLOADED_FILES_COUNTER.labels(filename=filename).inc()

    response = Response(
        chunks(),
        mimetype=guess_type(filename)[0] or "application/octet-stream"
    )

    if size is not None:
        response.headers["Content-Length"] = size

    return response


if __name__ == "__main__":
    app.run(debug=True)