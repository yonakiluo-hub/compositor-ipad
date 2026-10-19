"""Protocol/color/coverage tests use controlled pixels, not AI output guesses."""

import io
import struct
import unittest
from unittest.mock import patch

from PIL import Image, ImageCms, PngImagePlugin

from bridge.images import make_result, mock_generate, normalize_inputs, validate_metadata


def metadata(width=4, height=2):
    return {
        "protocolVersion": 1,
        "clientRequestId": "request-001",
        "documentId": "document-001",
        "baseRevision": 17,
        "sourceLayerIds": ["layer-001"],
        "canvasSize": {"width": width + 10, "height": height + 10},
        "cropRect": {"x": 3, "y": 5, "width": width, "height": height},
        "inputSize": {"width": width, "height": height},
        "colorSpace": "sRGB",
        "maskConvention": "white_edit_black_preserve",
        "workflowPreset": "paint-edit-v1",
        "prompt": "保持轮廓，试试侧光",
        "seed": 123456,
    }


def encoded(image, format="PNG", **kwargs):
    stream = io.BytesIO()
    image.save(stream, format=format, **kwargs)
    return stream.getvalue()


def read_image(blob):
    with Image.open(io.BytesIO(blob)) as image:
        image.load()
        return image.copy()


class MetadataTests(unittest.TestCase):
    def test_valid_metadata_is_independent(self):
        original = metadata()
        actual = validate_metadata(original)
        actual["cropRect"]["x"] = 0
        self.assertEqual(original["cropRect"]["x"], 3)

    def test_invalid_scalar_types_and_values(self):
        for field, value in [
            ("protocolVersion", True), ("protocolVersion", 2),
            ("baseRevision", -1), ("baseRevision", float("nan")),
            ("baseRevision", 1.0), ("seed", True), ("seed", 2**63),
            ("documentId", "../secret"), ("clientRequestId", ""),
            ("documentId", "document.part"), ("clientRequestId", "urn:request"),
            ("documentId", "a" * 129), ("sourceLayerIds", "layer"),
            ("sourceLayerIds", [None]), ("sourceLayerIds", ["bad/id"]),
            ("prompt", 23), ("prompt", "a" * 4001), ("prompt", "\ud800"),
            ("workflowPreset", []), ("workflowPreset", "arbitrary-workflow"),
            ("colorSpace", "Display P3"), ("maskConvention", "black_edit"),
        ]:
            with self.subTest(field=field, value=value):
                data = metadata()
                data[field] = value
                with self.assertRaises(ValueError):
                    validate_metadata(data)

    def test_unknown_and_missing_fields_rejected(self):
        for field in (None, "cropRect", "inputSize", "canvasSize"):
            data = metadata()
            target = data if field is None else data[field]
            target["unexpected"] = 12
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_metadata(data)
        data = metadata()
        del data["seed"]
        with self.assertRaises(ValueError):
            validate_metadata(data)

    def test_geometry_rejected(self):
        for field, key, value in [
            ("inputSize", "width", 0), ("inputSize", "width", 5),
            ("inputSize", "width", float("nan")),
            ("cropRect", "x", -1), ("cropRect", "x", 100),
            ("cropRect", "y", 100), ("cropRect", "height", True),
            ("canvasSize", "width", 30001), ("canvasSize", "height", "12"),
        ]:
            data = metadata()
            data[field][key] = value
            with self.subTest(field=field, key=key, value=value), self.assertRaises(ValueError):
                validate_metadata(data)
        with self.assertRaises(ValueError):
            validate_metadata(metadata(2049, 2048))

    def test_metadata_boundary_and_empty_layers(self):
        data = metadata(2048, 2048)
        data["seed"] = 2**63 - 1
        data["sourceLayerIds"] = []
        self.assertEqual(validate_metadata(data), data)


class ImageTests(unittest.TestCase):
    def setUp(self):
        self.meta = metadata()
        self.image = encoded(Image.new("RGBA", (4, 2), (31, 74, 219, 200)))
        self.mask = encoded(Image.new("L", (4, 2), 255))

    def test_normalize_preserves_pixels_and_declares_srgb(self):
        image, mask = normalize_inputs(self.image, self.mask, self.meta)
        actual = read_image(image)
        self.assertEqual(actual.mode, "RGBA")
        self.assertEqual(actual.getpixel((0, 0)), (31, 74, 219, 200))
        self.assertTrue(actual.info.get("icc_profile"))
        self.assertEqual(read_image(mask).mode, "L")
        self.assertEqual(read_image(mask).getpixel((0, 0)), 255)

    def test_black_mask_protects_original_exactly(self):
        coverage = Image.new("L", (4, 2), 255)
        coverage.putpixel((0, 0), 0)
        coverage.putpixel((3, 1), 0)
        layer = read_image(make_result(
            encoded(Image.new("RGB", (4, 2), "red")), encoded(coverage), self.meta,
        ))
        original = read_image(self.image)
        composited = Image.alpha_composite(original, layer)
        for point in ((0, 0), (3, 1)):
            self.assertEqual(layer.getpixel(point)[3], 0)
            self.assertEqual(composited.getpixel(point), original.getpixel(point))
        self.assertEqual(layer.getpixel((1, 0)), (255, 0, 0, 255))

    def test_gray_coverage_multiplies_existing_alpha_without_inverting(self):
        coverage = Image.new("L", (4, 2))
        coverage.putdata([0, 64, 128, 255] * 2)
        layer = read_image(make_result(self.image, encoded(coverage), self.meta))
        self.assertEqual([layer.getpixel((x, 0))[3] for x in range(4)], [0, 50, 100, 200])
        self.assertEqual(layer.getpixel((3, 0))[:3], (31, 74, 219))

    def test_non_square_result_restores_size_and_does_not_flip(self):
        generated = Image.new("RGB", (2, 4))
        for y in range(4):
            for x in range(2):
                generated.putpixel((x, y), (255 if x == 0 else 0, 0, 255 if y >= 2 else 0))
        layer = read_image(make_result(encoded(generated), self.mask, self.meta))
        self.assertEqual(layer.size, (4, 2))
        self.assertGreater(layer.getpixel((0, 0))[0], layer.getpixel((3, 0))[0])
        self.assertLess(layer.getpixel((0, 0))[2], layer.getpixel((0, 1))[2])

    def test_wrong_input_dimensions_are_rejected(self):
        wrong = encoded(Image.new("RGBA", (2, 4)))
        with self.assertRaisesRegex(ValueError, "dimensions"):
            normalize_inputs(wrong, self.mask, self.meta)
        wrong_mask = encoded(Image.new("L", (3, 2)))
        with self.assertRaisesRegex(ValueError, "dimensions"):
            make_result(self.image, wrong_mask, self.meta)

    def test_mask_jpeg_rgb_alpha_palette_and_transparency_rejected(self):
        invalid = [
            encoded(Image.new("L", (4, 2)), format="JPEG"),
            encoded(Image.new("RGB", (4, 2))),
            encoded(Image.new("LA", (4, 2))),
            encoded(Image.new("P", (4, 2))),
            encoded(Image.new("L", (4, 2)), transparency=0),
        ]
        for mask in invalid:
            with self.subTest(header=mask[:20]), self.assertRaises(ValueError):
                normalize_inputs(self.image, mask, self.meta)

    def test_corrupt_and_non_png_inputs_rejected(self):
        for image in (b"invalid", self.image[:-15], encoded(Image.new("RGB", (4, 2)), "JPEG")):
            with self.subTest(header=image[:20]), self.assertRaises(ValueError):
                normalize_inputs(image, self.mask, self.meta)
        with self.assertRaises(ValueError):
            make_result(b"broken", self.mask, self.meta)

    def test_sixteen_bit_png_rejected(self):
        image = encoded(Image.new("I;16", (4, 2), 32768))
        with self.assertRaisesRegex(ValueError, "8-bit"):
            normalize_inputs(image, self.mask, self.meta)
        with self.assertRaisesRegex(ValueError, "8-bit"):
            normalize_inputs(self.image, image, self.meta)

    def test_animation_rejected(self):
        first = Image.new("RGBA", (4, 2), "red")
        second = Image.new("RGBA", (4, 2), "blue")
        animated = encoded(first, save_all=True, append_images=[second], duration=100, loop=0)
        with self.assertRaisesRegex(ValueError, "one frame"):
            normalize_inputs(animated, self.mask, self.meta)

    def test_srgb_profile_converted_without_discarding_alpha(self):
        profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
        image = encoded(read_image(self.image), icc_profile=profile)
        normalized, _ = normalize_inputs(image, self.mask, self.meta)
        self.assertEqual(read_image(normalized).getpixel((0, 0)), (31, 74, 219, 200))

    def test_invalid_profile_and_mask_profile_rejected(self):
        invalid = encoded(read_image(self.image), icc_profile=b"not an ICC profile")
        with self.assertRaisesRegex(ValueError, "color conversion"):
            normalize_inputs(invalid, self.mask, self.meta)
        profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
        tagged_mask = encoded(read_image(self.mask), icc_profile=profile)
        with self.assertRaisesRegex(ValueError, "coverage"):
            normalize_inputs(self.image, tagged_mask, self.meta)

    def test_non_srgb_gamma_and_primaries_are_not_silently_ignored(self):
        info = PngImagePlugin.PngInfo()
        info.add(b"gAMA", struct.pack(">I", 100000))
        wrong_gamma = encoded(read_image(self.image), pnginfo=info)
        with self.assertRaisesRegex(ValueError, "gamma"):
            normalize_inputs(wrong_gamma, self.mask, self.meta)
        info = PngImagePlugin.PngInfo()
        info.add(b"cHRM", struct.pack(">8I", 31270, 32900, 68000, 32000, 26500, 69000, 15000, 6000))
        wrong_primaries = encoded(read_image(self.image), pnginfo=info)
        with self.assertRaisesRegex(ValueError, "primaries"):
            normalize_inputs(wrong_primaries, self.mask, self.meta)

    def test_generated_jpeg_is_supported(self):
        generated = encoded(Image.new("RGB", (2, 1), (120, 40, 30)), "JPEG")
        self.assertEqual(read_image(make_result(generated, self.mask, self.meta)).size, (4, 2))

    def test_declared_pixel_limit_blocks_decode(self):
        with patch("bridge.images.MAX_GENERATED_PIXELS", 7):
            with self.assertRaisesRegex(ValueError, "pixels"):
                make_result(self.image, self.mask, self.meta)

    def test_mock_is_deterministic_changed_and_labelled(self):
        source = encoded(Image.new("RGBA", (120, 30), (150, 200, 100, 255)))
        first, second = mock_generate(source), mock_generate(source)
        self.assertEqual(first, second)
        image = read_image(first)
        self.assertNotEqual(image.getpixel((110, 25)), (150, 200, 100, 255))
        self.assertGreater(len({image.getpixel((x, y)) for x in range(95) for y in range(14)}), 2)


if __name__ == "__main__":
    unittest.main()
