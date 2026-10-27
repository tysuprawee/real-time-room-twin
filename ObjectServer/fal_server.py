"""fal.ai fallback for RoomTwin's local SAM 3 / SAM 3D object server.

The iPhone speaks the same small API as ObjectServer/server.py.  This process
runs on the Mac, keeps FALKEY off the phone, and uses fal's hosted
``fal-ai/sam-3/3d-objects`` queue when the Colab server is unavailable or a
local generation fails.

    FALKEY=... OBJECT_SERVER_TOKEN=... python3 fal_server.py --port 8766

Only Python, Pillow and NumPy are needed.  Homebrew's ``assimp`` converts the
returned GLB to a triangle PLY; the PLY is then fitted to the photographed
RoomPlan box and rewritten in RoomTwin's exact binary layout.
"""

import argparse
import base64
import hashlib
import io
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
FURNITURE_DIR = os.environ.get("FURNITURE_DIR", os.path.join(os.path.dirname(HERE), "Furniture"))
sys.path.insert(0, FURNITURE_DIR)
import scan_io  # noqa: E402

ROOT = os.environ.get("FAL_OBJECTS_DIR", os.path.join(tempfile.gettempdir(), "roomtwin-fal-objects"))
TOKEN = os.environ["OBJECT_SERVER_TOKEN"]
FALKEY = os.environ["FALKEY"]
FAL_ENDPOINT = "https://queue.fal.run/fal-ai/sam-3/3d-objects"
FAL_SEGMENT_ENDPOINT = "https://queue.fal.run/fal-ai/sam-3/image"
ASSIMP = os.environ.get("ASSIMP") or shutil.which("assimp")
RCLONE = os.environ.get("RCLONE") or shutil.which("rclone")
DRIVE_REMOTE = os.environ.get("ROOMTWIN_DRIVE_REMOTE", "roomtwin-owner:RoomTwin")
MAX_SECONDS = 360
FAL_ACCESS_ERROR = None
DRIVE_ACCESS_ERROR = None


class FalAPIError(RuntimeError):
    pass


def safe_drive_parts(parts, filenames=False):
    values = [urllib.parse.unquote(value) for value in parts]
    pattern = r"[A-Za-z0-9._-]{1,128}" if filenames else r"[A-Za-z0-9-]{1,128}"
    if not values or any(not re.fullmatch(pattern, value) or value in (".", "..") for value in values):
        raise ValueError("invalid Drive path")
    return values


def drive_path(user, room, filename=None, kind="legacy-rooms"):
    user, room = safe_drive_parts([user, room])
    if kind not in {"legacy-rooms", "rooms", "objects"}:
        raise ValueError("unsupported Drive collection")
    root = DRIVE_REMOTE.rstrip('/')
    path = (f"{root}/{user}/{room}" if kind == "legacy-rooms" else
            f"{root}/Users/{user}/{kind.title()}/{room}")
    if filename is not None:
        filename = safe_drive_parts([filename], filenames=True)[0]
        allowed = {"model.usdz", "thumb.jpg"} if kind == "objects" else {
            "room.usdz", "room.ply", "room.json", "room-edits.json"}
        if filename not in allowed:
            raise ValueError("unsupported Drive file")
        path += "/" + filename
    return path


def check_drive():
    if not RCLONE:
        return "rclone is not installed on the RoomTwin server."
    remote = DRIVE_REMOTE.split(":", 1)[0] + ":"
    result = subprocess.run([RCLONE, "listremotes"], capture_output=True, text=True, timeout=15)
    if result.returncode or remote not in result.stdout.splitlines():
        return (f"Owner Google Drive is not connected. Run: rclone config create "
                f"{remote[:-1]} drive scope drive config_is_local true")
    return None


def drive_upload(stream, length, destination):
    if DRIVE_ACCESS_ERROR:
        raise RuntimeError(DRIVE_ACCESS_ERROR)
    temporary = tempfile.NamedTemporaryFile(prefix="roomtwin-drive-", delete=False)
    try:
        remaining = length
        with temporary:
            while remaining:
                block = stream.read(min(1024 * 1024, remaining))
                if not block:
                    raise ValueError("room upload ended early")
                temporary.write(block)
                remaining -= len(block)
        result = subprocess.run([RCLONE, "copyto", temporary.name, destination,
                                 "--drive-chunk-size", "64M", "--retries", "3"],
                                capture_output=True, text=True, timeout=3600)
        if result.returncode:
            raise RuntimeError((result.stderr or result.stdout or "Google Drive upload failed")[-1000:])
    finally:
        try:
            os.remove(temporary.name)
        except FileNotFoundError:
            pass


def drive_download(source):
    if DRIVE_ACCESS_ERROR:
        raise RuntimeError(DRIVE_ACCESS_ERROR)
    temporary = tempfile.NamedTemporaryFile(prefix="roomtwin-drive-", delete=False)
    temporary.close()
    result = subprocess.run([RCLONE, "copyto", source, temporary.name, "--retries", "3"],
                            capture_output=True, text=True, timeout=3600)
    if result.returncode:
        try:
            os.remove(temporary.name)
        except FileNotFoundError:
            pass
        raise FileNotFoundError((result.stderr or result.stdout or source)[-1000:])
    return temporary.name


def drive_delete(directory):
    if DRIVE_ACCESS_ERROR:
        raise RuntimeError(DRIVE_ACCESS_ERROR)
    result = subprocess.run([RCLONE, "purge", directory], capture_output=True, text=True, timeout=600)
    if result.returncode and "directory not found" not in (result.stderr or "").lower():
        raise RuntimeError((result.stderr or result.stdout or "Google Drive delete failed")[-1000:])


def write_json(path, value):
    with open(path + ".tmp", "w") as file:
        json.dump(value, file)
    os.replace(path + ".tmp", path)


def request_json(url, method="GET", body=None, timeout=60):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Key {FALKEY}")
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")
        if error.code == 401:
            raise FalAPIError(
                "fal.ai rejected FALKEY. Create a new API key in the fal.ai dashboard, "
                "update .env.local, then restart ObjectServer/start.sh.") from error
        if error.code == 403:
            raise FalAPIError(
                "FALKEY is valid but does not have access to fal-ai/sam-3/3d-objects.") from error
        raise FalAPIError(f"fal.ai HTTP {error.code}: {detail[:500]}") from error


def fal_access_error():
    """Checks authentication with malformed JSON, which can never start a paid job."""
    request = urllib.request.Request(FAL_ENDPOINT, data=b"{", method="POST")
    request.add_header("Authorization", f"Key {FALKEY}")
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=20):
            return None
    except urllib.error.HTTPError as error:
        if error.code in (400, 422):
            return None  # Authentication passed; only the intentionally invalid JSON failed.
        if error.code == 401:
            return ("fal.ai rejected FALKEY. Create a new API key in the fal.ai dashboard, "
                    "update .env.local, then restart ObjectServer/start.sh.")
        if error.code == 403:
            return "FALKEY does not have access to fal-ai/sam-3/3d-objects."
        return f"fal.ai key check returned HTTP {error.code}."
    except Exception as error:
        return f"Could not verify FALKEY with fal.ai: {type(error).__name__}: {error}"


def download(url, path):
    request = urllib.request.Request(url, headers={"User-Agent": "RoomTwin/1"})
    with urllib.request.urlopen(request, timeout=120) as response, open(path, "wb") as file:
        shutil.copyfileobj(response, file)


def photo_dir(photo_id):
    if not re.fullmatch(r"[0-9a-f]{12}", photo_id):
        raise LookupError(photo_id)
    path = os.path.join(ROOT, photo_id)
    if not os.path.isdir(path):
        raise LookupError(photo_id)
    return path


def load_entry(photo_id):
    with open(os.path.join(photo_dir(photo_id), "entry.json")) as file:
        return json.load(file)


def fingerprint(entry, image):
    """Stable identity for one photographed RoomPlan target across app retries."""
    target = {key: entry.get(key) for key in (
        "targetIdentifier", "targetCategory", "targetDimensions", "targetTransform")}
    digest = hashlib.sha256()
    # Bump whenever conversion/fitting changes so an old untextured cached
    # PLY is never reused after the pipeline is corrected.
    digest.update(b"roomtwin-fal-model-v2-photo-colour")
    digest.update(json.dumps(target, sort_keys=True, separators=(",", ":")).encode())
    digest.update(image)
    return digest.hexdigest()


def photo_fingerprint(photo_id):
    path = photo_dir(photo_id)
    stored = os.path.join(path, "fingerprint.txt")
    if os.path.exists(stored):
        return open(stored).read().strip()
    entry = load_entry(photo_id)
    with open(os.path.join(path, entry["image"]), "rb") as file:
        value = fingerprint(entry, file.read())
    with open(stored, "w") as file:
        file.write(value)
    return value


def cached_model(photo_id):
    wanted = photo_fingerprint(photo_id)
    for candidate in sorted(os.listdir(ROOT), reverse=True):
        if candidate == photo_id or not re.fullmatch(r"[0-9a-f]{12}", candidate):
            continue
        try:
            if photo_fingerprint(candidate) != wanted:
                continue
        except (LookupError, OSError, ValueError, KeyError):
            continue
        path = os.path.join(ROOT, candidate)
        for name in sorted(os.listdir(path), reverse=True):
            model = os.path.join(path, name, "model.ply")
            if name.startswith("job-") and os.path.isfile(model) and os.path.getsize(model) > 0:
                return model
    return None


def load_keyframe(photo_id):
    path = photo_dir(photo_id)
    return scan_io.Keyframe(path, load_entry(photo_id))


def add_photo(body):
    photo_id = uuid.uuid4().hex[:12]
    path = os.path.join(ROOT, photo_id)
    os.makedirs(os.path.join(path, "keyframes"))
    entry = dict(body["entry"], index=0, image="keyframes/000000.jpg", depth="keyframes/000000.depth",
                 confidence="keyframes/000000.conf")
    decoded = {key: base64.b64decode(body[key]) for key in ("image", "depth", "confidence")}
    for key in ("image", "depth", "confidence"):
        with open(os.path.join(path, entry[key]), "wb") as file:
            file.write(decoded[key])
    write_json(os.path.join(path, "entry.json"), entry)
    with open(os.path.join(path, "fingerprint.txt"), "w") as file:
        file.write(fingerprint(entry, decoded["image"]))
    keyframe = load_keyframe(photo_id)
    return dict(id=photo_id, turns=keyframe.turns, width=keyframe.width, height=keyframe.height)


def roomplan_box(photo_id):
    entry = load_entry(photo_id)
    dimensions = np.asarray(entry["targetDimensions"], np.float64)
    transform = np.asarray(entry["targetTransform"], np.float64).reshape(4, 4, order="F")
    target = dict(dimensions=dimensions, transform=transform, inverse=np.linalg.inv(transform))
    keyframe = load_keyframe(photo_id)
    box = scan_io.projected_target_box(keyframe, target)
    if box is None:
        raise ValueError("the RoomPlan target is behind the camera")
    box[[0, 2]] = np.clip(box[[0, 2]], 0, keyframe.width - 1)
    box[[1, 3]] = np.clip(box[[1, 3]], 0, keyframe.height - 1)
    if box[2] - box[0] < 2 or box[3] - box[1] < 2:
        raise ValueError("the detected furniture box is too small")
    return keyframe, box


def image_data_url(photo_id):
    keyframe = load_keyframe(photo_id)
    buffer = io.BytesIO()
    Image.fromarray(keyframe.image).save(buffer, "JPEG", quality=92)
    return "data:image/jpeg;base64," + base64.b64encode(buffer.getvalue()).decode("ascii")


def file_bytes(url):
    if url.startswith("data:"):
        return base64.b64decode(url.split(",", 1)[1])
    request = urllib.request.Request(url, headers={"User-Agent": "RoomTwin/1"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def mask_overlay(url):
    """Turns fal's binary mask into the same blue/white overlay the iPhone expects."""
    image = Image.open(io.BytesIO(file_bytes(url)))
    if "A" in image.getbands():
        alpha = image.getchannel("A")
        # Some mask files are opaque grayscale PNGs; use alpha only when it
        # actually separates foreground from background.
        mask = alpha if alpha.getextrema()[0] != alpha.getextrema()[1] else image.convert("L")
    else:
        mask = image.convert("L")
    mask = mask.point(lambda value: 255 if value >= 128 else 0)
    mask.thumbnail((max(mask.width // 2, 1), max(mask.height // 2, 1)), Image.Resampling.NEAREST)
    rgba = Image.new("RGBA", mask.size, (10, 132, 255, 0))
    rgba.putalpha(mask.point(lambda value: 110 if value else 0))
    edge = mask.filter(ImageFilter.FIND_EDGES).point(lambda value: 255 if value else 0)
    white = Image.new("RGBA", mask.size, (255, 255, 255, 255))
    rgba.alpha_composite(Image.composite(white, Image.new("RGBA", mask.size), edge))
    buffer = io.BytesIO()
    rgba.save(buffer, "PNG")
    area = float(np.asarray(mask, np.uint8).mean() / 255.0)
    return base64.b64encode(buffer.getvalue()).decode("ascii"), area


def fal_segment(photo_id, guidance):
    # fal's schema gives `prompt` a sample default (currently "wheel").  When
    # it is omitted that default can be combined with a point/box and cause an
    # otherwise valid visual selection to return no masks.  An explicit empty
    # prompt makes point and box guidance truly visual-only.
    inputs = dict(image_url=image_data_url(photo_id), prompt="", apply_mask=False,
                  output_format="png", return_multiple_masks=True, max_masks=3,
                  include_scores=True, include_boxes=True, **guidance)
    result = fal_result(FAL_SEGMENT_ENDPOINT, inputs, lambda _message: None, max_seconds=180)
    masks = result.get("masks") or []
    scores = result.get("scores") or []
    metadata = result.get("metadata") or []
    values = []
    for index, mask in enumerate(masks):
        url = mask.get("url") if isinstance(mask, dict) else mask
        if not url:
            continue
        score = scores[index] if index < len(scores) else (
            metadata[index].get("score", 1.0) if index < len(metadata) else 1.0)
        overlay, area = mask_overlay(url)
        values.append(dict(url=url, overlay=overlay, score=float(score or 0), area=area))
    if not values:
        raise FalAPIError("fal.ai SAM 3 returned no mask for that selection. Tap near the centre of the object and retry.")
    values.sort(key=lambda item: item["score"], reverse=True)
    write_json(os.path.join(photo_dir(photo_id), "fal-masks.json"), values)
    return values


def segment_target(photo_id, body):
    keyframe, box = roomplan_box(photo_id)
    guidance = dict(box_prompts=[dict(
        x_min=int(round(box[0])), y_min=int(round(box[1])),
        x_max=int(round(box[2])), y_max=int(round(box[3])))])
    masks = fal_segment(photo_id, guidance)
    write_json(os.path.join(photo_dir(photo_id), "segment.json"),
               dict(mask_urls=[masks[0]["url"]]))
    area = float((box[2] - box[0]) * (box[3] - box[1]) / (keyframe.width * keyframe.height))
    return dict(mask=0, score=masks[0]["score"], overlap=1.0, area=area, provider="fal.ai")


def select(photo_id, body):
    """Resolve positive points on one object before charging for 3D generation."""
    keyframe = load_keyframe(photo_id)
    requested = body.get("points") or [body]
    if not requested:
        raise ValueError("at least one selection point is required")
    point_prompts = [dict(
        x=int(np.clip(float(point["x"]), 0, 1) * (keyframe.width - 1)),
        y=int(np.clip(float(point["y"]), 0, 1) * (keyframe.height - 1)),
        label=1 if int(point.get("label", 1)) else 0,
        object_id=0) for point in requested]
    masks = fal_segment(photo_id, dict(point_prompts=point_prompts))
    return dict(masks=[dict(overlay=item["overlay"], score=item["score"], area=item["area"])
                       for item in masks], best=0, provider="fal.ai")


def make_job(photo_id, body):
    path = photo_dir(photo_id)
    options_path = os.path.join(path, "fal-masks.json")
    if os.path.exists(options_path):
        with open(options_path) as file:
            masks = json.load(file)
        selected = int(body.get("mask", 0))
        if selected < 0 or selected >= len(masks):
            raise ValueError("the selected mask is no longer available")
        write_json(os.path.join(path, "segment.json"), dict(mask_urls=[masks[selected]["url"]]))
    if not os.path.exists(os.path.join(path, "segment.json")):
        raise ValueError("select or frame the object first")
    number = len([name for name in os.listdir(path) if name.startswith("job-")])
    directory = os.path.join(path, f"job-{number}")
    os.makedirs(directory)
    write_json(os.path.join(directory, "request.json"),
               dict(mask=int(body.get("mask", 0)), preserveWorld=bool(body.get("preserveWorld", False)),
                    created=time.time()))
    job = f"{photo_id}-{number}"
    cached = cached_model(photo_id)
    if cached:
        shutil.copy2(cached, os.path.join(directory, "model.ply"))
        write_json(os.path.join(directory, "status.json"), dict(
            state="done", message="Reused the existing fal.ai result",
            provider="fal.ai cache", seconds=0))
        return dict(job=job, provider="fal.ai cache")
    threading.Thread(target=run_job, args=(job,), daemon=True).start()
    return dict(job=job, provider="fal.ai")


def job_dir(job):
    match = re.fullmatch(r"([0-9a-f]{12})-(\d+)", job)
    if not match:
        raise LookupError(job)
    path = os.path.join(photo_dir(match[1]), f"job-{match[2]}")
    if not os.path.isdir(path):
        raise LookupError(job)
    return path


def job_status(job):
    path = os.path.join(job_dir(job), "status.json")
    if not os.path.exists(path):
        return dict(state="queued", message="Waiting for fal.ai", provider="fal.ai")
    with open(path) as file:
        return json.load(file)


def fal_result(endpoint, inputs, status, max_seconds=MAX_SECONDS):
    status("Submitting to fal.ai")
    queued = request_json(endpoint, "POST", inputs, timeout=90)
    immediate = queued.get("data", queued)
    if any(key in immediate for key in ("model_glb", "individual_glbs", "masks")):
        return immediate
    status_url = queued.get("status_url")
    response_url = queued.get("response_url")
    if not status_url or not response_url:
        raise RuntimeError(f"fal.ai returned no queue URLs: {queued}")
    started = time.time()
    while time.time() - started < max_seconds:
        update = request_json(status_url, timeout=30)
        state = update.get("status")
        if state == "COMPLETED":
            status("Downloading the hosted SAM result")
            result = request_json(response_url, timeout=120)
            return result.get("data", result)
        if state in ("FAILED", "CANCELLED"):
            raise RuntimeError(update.get("error") or f"fal.ai job {state.lower()}")
        logs = update.get("logs") or []
        message = logs[-1].get("message") if logs and isinstance(logs[-1], dict) else None
        status(message or ("Running on fal.ai" if state == "IN_PROGRESS" else "Queued on fal.ai"))
        time.sleep(1)
    raise TimeoutError(f"fal.ai did not finish within {max_seconds} seconds")


def model_url(result):
    individuals = result.get("individual_glbs") or []
    if individuals and individuals[0].get("url"):
        return individuals[0]["url"]
    model = result.get("model_glb") or result.get("model_mesh") or {}
    if model.get("url"):
        return model["url"]
    raise RuntimeError("fal.ai returned no GLB model")


PLY_TYPES = {
    "char": "b", "int8": "b", "uchar": "B", "uint8": "B",
    "short": "h", "int16": "h", "ushort": "H", "uint16": "H",
    "int": "i", "int32": "i", "uint": "I", "uint32": "I",
    "float": "f", "float32": "f", "double": "d", "float64": "d",
}


def read_assimp_ply(path):
    """Reads Assimp's ASCII or binary PLY, including extra vertex properties."""
    data = open(path, "rb").read()
    marker = data.find(b"end_header")
    if marker < 0:
        raise ValueError("Assimp produced a PLY with no header")
    end = data.find(b"\n", marker)
    if end < 0:
        raise ValueError("Assimp produced an incomplete PLY header")
    end += 1
    lines = data[:end].decode("ascii").splitlines()
    is_binary = "format binary_little_endian 1.0" in lines
    is_ascii = "format ascii 1.0" in lines
    if not is_binary and not is_ascii:
        raise ValueError("Assimp produced an unsupported PLY encoding")
    elements = []
    current = None
    for line in lines:
        words = line.split()
        if words[:1] == ["element"]:
            current = dict(name=words[1], count=int(words[2]), properties=[])
            elements.append(current)
        elif words[:1] == ["property"] and current is not None:
            if words[1] == "list":
                current["properties"].append(("list", words[2], words[3], words[4]))
            else:
                current["properties"].append(("scalar", words[1], words[2]))

    offset = end
    vertices = []
    colours = []
    faces = []
    ascii_lines = iter(data[end:].decode("ascii").splitlines()) if is_ascii else None
    integer_types = {
        "char", "int8", "uchar", "uint8", "short", "int16", "ushort", "uint16",
        "int", "int32", "uint", "uint32",
    }

    def scalar(kind):
        nonlocal offset
        code = PLY_TYPES[kind]
        value = struct.unpack_from("<" + code, data, offset)[0]
        offset += struct.calcsize(code)
        return value

    def ascii_value(kind, token):
        return int(token) if kind in integer_types else float(token)

    def record(element):
        if is_binary:
            values, lists = {}, {}
            for prop in element["properties"]:
                if prop[0] == "scalar":
                    values[prop[2]] = scalar(prop[1])
                else:
                    count = scalar(prop[1])
                    lists[prop[3]] = [scalar(prop[2]) for _ in range(count)]
            return values, lists

        words = []
        while not words:
            try:
                words = next(ascii_lines).split()
            except StopIteration as error:
                raise ValueError("Assimp ASCII PLY ended before its declared elements") from error
        cursor = 0
        values, lists = {}, {}
        for prop in element["properties"]:
            if prop[0] == "scalar":
                values[prop[2]] = ascii_value(prop[1], words[cursor])
                cursor += 1
            else:
                count = int(words[cursor])
                cursor += 1
                lists[prop[3]] = [ascii_value(prop[2], word)
                                  for word in words[cursor:cursor + count]]
                cursor += count
        return values, lists

    for element in elements:
        for _ in range(element["count"]):
            values, lists = record(element)
            if element["name"] == "vertex":
                vertices.append((values["x"], values["y"], values["z"]))
                colour = [values.get(name, values.get(short, 184))
                          for name, short in (("red", "r"), ("green", "g"), ("blue", "b"))]
                if max(colour) <= 1:
                    colour = [round(channel * 255) for channel in colour]
                colours.append(tuple(np.clip(colour, 0, 255)))
            elif element["name"] == "face":
                indices = lists.get("vertex_indices", lists.get("vertex_index", []))
                for index in range(1, len(indices) - 1):
                    faces.append((indices[0], indices[index], indices[index + 1]))
    return (np.asarray(vertices, np.float32), np.asarray(colours, np.uint8),
            np.asarray(faces, np.int64))


def fit_to_target(positions, photo_id):
    entry = load_entry(photo_id)
    dimensions = entry.get("targetDimensions")
    transform_value = entry.get("targetTransform")
    if not dimensions or not transform_value:
        # Object mode has no semantic box. Stand the object at the origin in
        # its generated scale; the existing library UI can resize it later.
        low, high = positions.min(0), positions.max(0)
        positions -= np.array([(low[0] + high[0]) / 2, low[1], (low[2] + high[2]) / 2], np.float32)
        return positions

    dimensions = np.asarray(dimensions, np.float32)
    transform = np.asarray(transform_value, np.float32).reshape(4, 4, order="F")
    low, high = positions.min(0), positions.max(0)
    size = np.maximum(high - low, 1e-5)
    source_ratio = size[0] / size[2]
    target_ratio = max(dimensions[0], 1e-5) / max(dimensions[2], 1e-5)
    if abs(np.log(source_ratio / target_ratio)) > abs(np.log((1 / source_ratio) / target_ratio)):
        positions = np.stack([positions[:, 2], positions[:, 1], -positions[:, 0]], axis=1)
        low, high = positions.min(0), positions.max(0)
        size = np.maximum(high - low, 1e-5)
    centre = np.array([(low[0] + high[0]) / 2, low[1], (low[2] + high[2]) / 2], np.float32)
    local = positions - centre
    scale = 0.96 * float(np.min(dimensions / size))
    local *= scale
    local[:, 1] -= dimensions[1] / 2
    return local @ transform[:3, :3].T + transform[:3, 3]


def colours_from_photo(positions, photo_id, fallback):
    """Bake the manual capture into vertex colours after RoomPlan fitting.

    fal's GLB material is lost when converted to RoomTwin's compact PLY. The
    capture is a better source anyway: it is the real object under the room's
    lighting. Rear vertices may project through the object onto the same
    image, which gives them a plausible colour instead of an untextured white.
    """
    keyframe = load_keyframe(photo_id)
    u, v, z = keyframe.project(positions)
    with np.errstate(invalid="ignore"):
        ui = np.round(np.nan_to_num(u, nan=-1, posinf=-1, neginf=-1)).astype(np.int64)
        vi = np.round(np.nan_to_num(v, nan=-1, posinf=-1, neginf=-1)).astype(np.int64)
    valid = ((z > 0.05) & (ui >= 0) & (ui < keyframe.width)
             & (vi >= 0) & (vi < keyframe.height))
    colours = np.asarray(fallback, np.uint8).copy()
    if len(colours) != len(positions):
        colours = np.full((len(positions), 3), 184, np.uint8)
    colours[valid] = keyframe.image[vi[valid], ui[valid], :3]
    return colours


def convert_glb(glb, destination, photo_id):
    if not ASSIMP:
        raise RuntimeError("assimp is required for fal.ai fallback (install with: brew install assimp)")
    raw = destination + ".assimp.ply"
    result = subprocess.run([ASSIMP, "export", glb, raw, "-f", "plyb"],
                            capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f"assimp conversion failed: {(result.stderr or result.stdout)[-500:]}")
    try:
        positions, colours, faces = read_assimp_ply(raw)
    finally:
        try:
            os.remove(raw)
        except FileNotFoundError:
            pass
    if not len(positions) or not len(faces):
        raise RuntimeError("fal.ai returned an empty triangle model")
    positions = fit_to_target(positions, photo_id)
    colours = colours_from_photo(positions, photo_id, colours)
    scan_io.write_ply(destination, positions, colours, faces,
                      comment="RoomTwin fal.ai SAM 3D fallback, metres, +y up")


def run_job(job):
    directory = job_dir(job)
    photo_id = job.split("-", 1)[0]
    status_path = os.path.join(directory, "status.json")
    started = time.time()

    def status(message):
        write_json(status_path, dict(state="running", message=message, provider="fal.ai",
                                     seconds=round(time.time() - started, 1)))

    try:
        with open(os.path.join(photo_dir(photo_id), "segment.json")) as file:
            guidance = json.load(file)
        inputs = dict(image_url=image_data_url(photo_id), seed=42, export_textured_glb=False,
                      enable_safety_checker=True, **guidance)
        result = fal_result(FAL_ENDPOINT, inputs, status)
        status("Converting the fal.ai model")
        glb = os.path.join(directory, "model.glb")
        download(model_url(result), glb)
        destination = os.path.join(directory, "model.ply")
        convert_glb(glb, destination, photo_id)
        write_json(status_path, dict(state="done", message="Done with fal.ai", provider="fal.ai",
                                     seconds=round(time.time() - started, 1)))
    except Exception as error:
        traceback.print_exc()
        message = str(error) if isinstance(error, FalAPIError) else f"fal.ai: {type(error).__name__}: {error}"
        write_json(status_path, dict(state="failed", message=message,
                                     provider="fal.ai", seconds=round(time.time() - started, 1)))


def make_handler():
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            self.route("GET")

        def do_POST(self):
            self.route("POST")

        def do_DELETE(self):
            self.route("DELETE")

        def route(self, method):
            try:
                if self.headers.get("X-Token") != TOKEN:
                    return self.reply(403, dict(error="wrong token"))
                path = self.path.split("?", 1)[0].strip("/").split("/")
                if method == "GET" and path == ["health"]:
                    state = "failed" if FAL_ACCESS_ERROR else "ready"
                    return self.reply(200, dict(generator=dict(
                        state=state, provider="fal.ai", message=FAL_ACCESS_ERROR),
                        drive=dict(state="failed" if DRIVE_ACCESS_ERROR else "ready",
                                   provider="Google Drive", message=DRIVE_ACCESS_ERROR)))
                kind = "legacy-rooms"
                if len(path) >= 5 and path[:2] == ["drive", "assets"]:
                    kind = path[2]
                    if kind not in {"rooms", "objects"}:
                        raise ValueError("unsupported Drive collection")
                    path = ["drive", "rooms"] + path[3:]
                if len(path) >= 4 and path[:2] == ["drive", "rooms"]:
                    if method == "POST" and len(path) == 5:
                        length = int(self.headers.get("Content-Length") or 0)
                        if length <= 0:
                            raise ValueError("empty room file")
                        destination = drive_path(path[2], path[3], path[4], kind=kind)
                        drive_upload(self.rfile, length, destination)
                        relative = path[2:] if kind == "legacy-rooms" else [kind] + path[2:]
                        return self.reply(200, dict(path="owner-drive:" + "/".join(relative)))
                    if method == "GET" and len(path) == 5:
                        temporary = drive_download(drive_path(path[2], path[3], path[4], kind=kind))
                        try:
                            return self.reply_file(200, temporary, "application/octet-stream")
                        finally:
                            try:
                                os.remove(temporary)
                            except FileNotFoundError:
                                pass
                    if method == "DELETE" and len(path) == 4:
                        drive_delete(drive_path(path[2], path[3], kind=kind))
                        return self.reply(200, dict(deleted=True))
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length)) if length else {}
                if method == "POST" and path == ["photos"]:
                    return self.reply(200, add_photo(body))
                if method == "POST" and len(path) == 3 and path[0] == "photos" and path[2] == "select":
                    return self.reply(200, select(path[1], body))
                if method == "POST" and len(path) == 3 and path[0] == "photos" and path[2] == "segment":
                    return self.reply(200, segment_target(path[1], body))
                if method == "POST" and len(path) == 3 and path[0] == "photos" and path[2] == "generate":
                    return self.reply(200, make_job(path[1], body))
                if method == "GET" and len(path) == 2 and path[0] == "jobs":
                    return self.reply(200, job_status(path[1]))
                if method == "GET" and len(path) == 3 and path[0] == "jobs" and path[2] == "model.ply":
                    with open(os.path.join(job_dir(path[1]), "model.ply"), "rb") as file:
                        return self.reply(200, file.read(), "application/octet-stream")
                return self.reply(404, dict(error="no such endpoint"))
            except (LookupError, FileNotFoundError) as error:
                return self.reply(404, dict(error=f"not found: {error}"))
            except (KeyError, ValueError) as error:
                return self.reply(400, dict(error=str(error)))
            except Exception as error:
                traceback.print_exc()
                return self.reply(500, dict(error=f"{type(error).__name__}: {error}"))

        def reply(self, status, body, content_type="application/json"):
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def reply_file(self, status, path, content_type):
            size = os.path.getsize(path)
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(size))
            self.end_headers()
            with open(path, "rb") as file:
                shutil.copyfileobj(file, self.wfile, length=1024 * 1024)

        def log_message(self, format, *args):
            if args and str(args[0]).startswith("GET /health"):
                return
            print(f"{self.address_string()} {format % args}", flush=True)

    return Handler


def main():
    global FAL_ACCESS_ERROR, DRIVE_ACCESS_ERROR
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args()
    if not ASSIMP:
        raise SystemExit("assimp not found; install it with: brew install assimp")
    os.makedirs(ROOT, exist_ok=True)
    FAL_ACCESS_ERROR = fal_access_error()
    DRIVE_ACCESS_ERROR = check_drive()
    if FAL_ACCESS_ERROR:
        print(f"fal.ai fallback unavailable: {FAL_ACCESS_ERROR}", flush=True)
    if DRIVE_ACCESS_ERROR:
        print(f"owner Drive unavailable: {DRIVE_ACCESS_ERROR}", flush=True)
    print(f"fal.ai SAM 3D fallback listening on {args.host}:{args.port}", flush=True)
    ThreadingHTTPServer((args.host, args.port), make_handler()).serve_forever()


if __name__ == "__main__":
    main()
