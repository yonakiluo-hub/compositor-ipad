"""Strict v1 image exchange and alpha-safe result preparation.

Coordinates are integer document pixels with a top-left origin. All returned
PNG pixels use straight (unassociated) alpha; do not premultiply them again in
the client. Unknown metadata fields are rejected, including nested fields.
"""

from __future__ import annotations

import copy
import io
import re
import warnings
from typing import Any

from PIL import Image, ImageChops, ImageCms, ImageDraw, ImageOps


MAX_INPUT_PIXELS = 4_194_304
MAX_GENERATED_PIXELS = 16_777_216
MAX_IMAGE_BYTES = 32 * 1024 * 1024
MAX_ICC_BYTES = 1024 * 1024
MAX_CANVAS_DIMENSION = 30_000
WORKFLOW_PRESETS = frozenset({"paint-edit-v1", "mock-paint-v1"})
_ID_PATTERN = re.compile(r"[A-Za-z0-9_-]{1,128}\Z", re.ASCII)
_METADATA_KEYS = frozenset(
    {
        "protocolVersion", "clientRequestId", "documentId", "baseRevision",
        "sourceLayerIds", "canvasSize", "cropRect", "inputSize", "colorSpace",
        "maskConvention", "workflowPreset", "prompt", "seed",
    }
)
_SRGB_PROFILE = ImageCms.createProfile("sRGB")
_SRGB_BYTES = ImageCms.ImageCmsProfile(_SRGB_PROFILE).tobytes()
_GENERATED_FORMATS = frozenset({"PNG", "JPEG", "WEBP", "BMP", "TIFF", "GIF"})


def _object_keys(value: Any, keys: set[str] | frozenset[str], name: str) -> dict:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")
    if set(value) != keys:
        missing = sorted(keys - set(value))
        unknown = sorted(str(key) for key in set(value) - keys)
        raise ValueError(f"{name} fields invalid; missing={missing}, unknown={unknown}")
    return value


def _integer(value: Any, low: int, high: int, name: str) -> int:
    # bool is a Python int subclass, but is not a JSON integer in this protocol.
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"{name} must be an integer between {low} and {high}")
    return value


def _identifier(value: Any, name: str) -> str:
    if not isinstance(value, str) or _ID_PATTERN.fullmatch(value) is None:
        raise ValueError(f"{name} must be a safe ASCII identifier of 1 to 128 characters")
    return value


def validate_metadata(value: dict, allowed_presets=WORKFLOW_PRESETS) -> dict:
    """Validate the complete v1 metadata and return an independent copy.

    The first version accepts exactly the documented fields, safe ASCII IDs,
    and at most 256 source layer IDs. It does not accept scaled uploads: input
    dimensions must equal the crop dimensions. A missing mask has no default.
    """
    _object_keys(value, _METADATA_KEYS, "metadata")
    _integer(value["protocolVersion"], 1, 1, "protocolVersion")
    _identifier(value["clientRequestId"], "clientRequestId")
    _identifier(value["documentId"], "documentId")
    _integer(value["baseRevision"], 0, 2**63 - 1, "baseRevision")
    layer_ids = value["sourceLayerIds"]
    if not isinstance(layer_ids, list) or len(layer_ids) > 256:
        raise ValueError("sourceLayerIds must be an array with at most 256 IDs")
    for index, layer_id in enumerate(layer_ids):
        _identifier(layer_id, f"sourceLayerIds[{index}]")

    dimensions = {}
    for field in ("canvasSize", "inputSize"):
        size = _object_keys(value[field], {"width", "height"}, field)
        dimensions[field] = tuple(
            _integer(size[axis], 1, MAX_CANVAS_DIMENSION, f"{field}.{axis}")
            for axis in ("width", "height")
        )
    crop = _object_keys(value["cropRect"], {"x", "y", "width", "height"}, "cropRect")
    for axis in ("x", "y"):
        _integer(crop[axis], 0, MAX_CANVAS_DIMENSION, f"cropRect.{axis}")
    for axis in ("width", "height"):
        _integer(crop[axis], 1, MAX_CANVAS_DIMENSION, f"cropRect.{axis}")
    canvas_width, canvas_height = dimensions["canvasSize"]
    if crop["x"] + crop["width"] > canvas_width or crop["y"] + crop["height"] > canvas_height:
        raise ValueError("cropRect must be entirely inside canvasSize")
    input_width, input_height = dimensions["inputSize"]
    if (input_width, input_height) != (crop["width"], crop["height"]):
        raise ValueError("inputSize must equal cropRect dimensions in protocol v1")
    if input_width * input_height > MAX_INPUT_PIXELS:
        raise ValueError(f"inputSize exceeds {MAX_INPUT_PIXELS} pixels")
    if value["colorSpace"] != "sRGB":
        raise ValueError("colorSpace must be sRGB")
    if value["maskConvention"] != "white_edit_black_preserve":
        raise ValueError("maskConvention must be white_edit_black_preserve")
    _identifier(value["workflowPreset"], "workflowPreset")
    if allowed_presets is not None and value["workflowPreset"] not in allowed_presets:
        raise ValueError("workflowPreset is unsupported")
    if not isinstance(value["prompt"], str) or len(value["prompt"]) > 4000:
        raise ValueError("prompt must be a string of at most 4000 characters")
    # JSON may contain lone surrogate escapes; reject them before persistence.
    try:
        value["prompt"].encode("utf-8")
    except UnicodeEncodeError as exc:
        raise ValueError("prompt must be valid Unicode") from exc
    _integer(value["seed"], 0, 2**63 - 1, "seed")
    return copy.deepcopy(value)


def _png_metadata_checks(data: bytes, kind: str) -> None:
    """Reject precision/HDR that the 8-bit sRGB exchange cannot preserve."""
    if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError(f"{kind} must be a PNG")
    if data[24] != 8:
        raise ValueError(f"{kind} PNG must use 8-bit channels")
    offset = 8
    while offset + 12 <= len(data):
        size = int.from_bytes(data[offset:offset + 4], "big")
        chunk_type = data[offset + 4:offset + 8]
        if size > len(data) - offset - 12:
            raise ValueError(f"{kind} PNG contains a truncated chunk")
        if chunk_type in {b"cICP", b"mDCv", b"cLLi"}:
            raise ValueError(f"{kind} contains unsupported HDR/color metadata; export 8-bit sRGB PNG")
        offset += size + 12
        if chunk_type == b"IEND":
            return
    raise ValueError(f"{kind} PNG is missing IEND")


def _decode(
    data: bytes,
    *,
    kind: str,
    png_only: bool,
    max_pixels: int,
    expected_size: tuple[int, int] | None = None,
    allow_orientation: bool = False,
) -> Image.Image:
    if not isinstance(data, bytes) or not data or len(data) > MAX_IMAGE_BYTES:
        raise ValueError(f"{kind} must contain 1 to {MAX_IMAGE_BYTES} bytes")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(data)) as probe:
                if (png_only and probe.format != "PNG") or probe.format not in _GENERATED_FORMATS:
                    raise ValueError(f"{kind} has an unsupported image format")
                if probe.format == "PNG":
                    _png_metadata_checks(data, kind)
                if getattr(probe, "n_frames", 1) != 1:
                    raise ValueError(f"{kind} must have exactly one frame")
                width, height = probe.size
                if width < 1 or height < 1 or width * height > max_pixels:
                    raise ValueError(f"{kind} exceeds {max_pixels} pixels")
                if width > MAX_CANVAS_DIMENSION or height > MAX_CANVAS_DIMENSION:
                    raise ValueError(f"{kind} dimension exceeds {MAX_CANVAS_DIMENSION}")
                if expected_size is not None and probe.size != expected_size:
                    raise ValueError(f"{kind} dimensions must equal inputSize")
                if probe.mode in {"I", "F"} or probe.mode.startswith("I;"):
                    raise ValueError(f"{kind} must use 8-bit channels")
                if probe.format == "TIFF":
                    bits = probe.tag_v2.get(258, (8,))
                    if isinstance(bits, int):
                        bits = (bits,)
                    if any(bit != 8 for bit in bits):
                        raise ValueError(f"{kind} TIFF must use 8-bit channels")
                probe.verify()
            with Image.open(io.BytesIO(data)) as decoded:
                orientation = decoded.getexif().get(274, 1)
                if not allow_orientation and orientation != 1:
                    raise ValueError(f"{kind} must bake EXIF orientation into its pixels")
                decoded.load()
                return ImageOps.exif_transpose(decoded) if allow_orientation else decoded.copy()
    except ValueError:
        raise
    except Exception as exc:
        raise ValueError(f"{kind} could not be decoded safely: {type(exc).__name__}") from exc


def _to_srgb(image: Image.Image, kind: str) -> Image.Image:
    """Convert an ICC-tagged image, or validate the declared sRGB fallback."""
    try:
        rgba = image.convert("RGBA")
        profile_bytes = image.info.get("icc_profile")
        if profile_bytes:
            if not isinstance(profile_bytes, bytes) or len(profile_bytes) > MAX_ICC_BYTES:
                raise ValueError(f"{kind} has an invalid or oversized ICC profile")
            source_profile = ImageCms.ImageCmsProfile(io.BytesIO(profile_bytes))
            color_space = source_profile.profile.xcolor_space.strip()
            if color_space == "RGB":
                color = image.convert("RGB")
            elif color_space == "GRAY" and image.mode in {"L", "LA"}:
                color = image.getchannel("L")
            elif color_space == "CMYK" and image.mode == "CMYK":
                color = image
            else:
                raise ValueError(f"{kind} ICC profile does not match its pixel color space")
            converted = ImageCms.profileToProfile(
                color, source_profile, _SRGB_PROFILE,
                outputMode="RGB", renderingIntent=ImageCms.Intent.RELATIVE_COLORIMETRIC,
            )
            rgba = converted.convert("RGBA")
            rgba.putalpha(image.convert("RGBA").getchannel("A"))
        else:
            if image.mode not in {"1", "L", "LA", "P", "RGB", "RGBA"}:
                raise ValueError(f"{kind} requires a valid ICC profile for this color space")
            # With no ICC, v1 explicitly declares sRGB. Refuse contradictory
            # legacy metadata rather than silently flatten wide-gamut colors.
            gamma = image.info.get("gamma")
            if gamma is not None and abs(float(gamma) - 0.45455) > 0.005:
                raise ValueError(f"{kind} has non-sRGB gamma; export an sRGB copy")
            chromaticity = image.info.get("chromaticity")
            srgb_chromaticity = (0.3127, 0.3290, 0.64, 0.33, 0.30, 0.60, 0.15, 0.06)
            if chromaticity is not None and (
                len(chromaticity) != 8
                or any(abs(float(a) - b) > 0.003 for a, b in zip(chromaticity, srgb_chromaticity))
            ):
                raise ValueError(f"{kind} has non-sRGB primaries without an ICC profile")
        return rgba
    except ValueError:
        raise
    except Exception as exc:
        raise ValueError(f"{kind} color conversion failed: {type(exc).__name__}") from exc


def _encode_png(image: Image.Image, *, srgb: bool = False) -> bytes:
    output = io.BytesIO()
    # A new image strips inherited EXIF, gamma, ICC, text, and stale metadata.
    clean = Image.frombytes(image.mode, image.size, image.tobytes())
    options = {"icc_profile": _SRGB_BYTES} if srgb else {}
    clean.save(output, format="PNG", **options)
    return output.getvalue()


def _mask(data: bytes, size: tuple[int, int]) -> Image.Image:
    mask = _decode(data, kind="mask", png_only=True, max_pixels=MAX_INPUT_PIXELS, expected_size=size)
    if mask.mode != "L" or "transparency" in mask.info:
        raise ValueError("mask must be an 8-bit grayscale PNG (L) without alpha or transparency")
    if mask.info.get("icc_profile"):
        raise ValueError("mask is numeric coverage and must not contain an ICC color profile")
    return mask


def normalize_inputs(image_bytes: bytes, mask_bytes: bytes, metadata: dict) -> tuple[bytes, bytes]:
    """Return an 8-bit straight-alpha sRGB RGBA PNG and exact L coverage PNG."""
    checked = validate_metadata(metadata, allowed_presets=None)
    size = (checked["inputSize"]["width"], checked["inputSize"]["height"])
    image = _decode(image_bytes, kind="image", png_only=True, max_pixels=MAX_INPUT_PIXELS, expected_size=size)
    mask = _mask(mask_bytes, size)
    return _encode_png(_to_srgb(image, "image"), srgb=True), _encode_png(mask)


def make_result(generated: bytes, mask: bytes, metadata: dict) -> bytes:
    """Restore crop size and restrict generated alpha to the submitted mask.

    The return value is a new layer, not a flattened replacement. Black mask
    pixels have exactly zero alpha, preserving the original when composited.
    Gray coverage multiplies any existing alpha using Pillow's integer floor.
    """
    checked = validate_metadata(metadata, allowed_presets=None)
    size = (checked["cropRect"]["width"], checked["cropRect"]["height"])
    coverage = _mask(mask, size)
    decoded = _decode(
        generated, kind="generated image", png_only=False,
        max_pixels=MAX_GENERATED_PIXELS, allow_orientation=True,
    )
    rgba = _to_srgb(decoded, "generated image")
    if rgba.size != size:
        rgba = rgba.resize(size, Image.Resampling.LANCZOS)
    rgba.putalpha(ImageChops.multiply(rgba.getchannel("A"), coverage))
    return _encode_png(rgba, srgb=True)


def mock_generate(image_bytes: bytes) -> bytes:
    """Deterministic colored preview with a visible MOCK / NO AI label."""
    decoded = _decode(image_bytes, kind="mock image", png_only=True, max_pixels=MAX_INPUT_PIXELS)
    rgba = _to_srgb(decoded, "mock image")
    original_alpha = rgba.getchannel("A")
    tint = Image.new("RGBA", rgba.size, (86, 45, 190, 255))
    result = Image.blend(rgba, tint, 0.35)
    result.putalpha(original_alpha)
    drawing = ImageDraw.Draw(result)
    drawing.rectangle((0, 0, min(result.width - 1, 99), min(result.height - 1, 14)), fill=(25, 0, 50, 255))
    drawing.text((2, 1), "MOCK / NO AI", fill=(255, 255, 255, 255))
    return _encode_png(result, srgb=True)
