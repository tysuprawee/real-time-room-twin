"""Check Drive namespaces and streaming routes without Google or paid fal jobs."""
import io
import os
import unittest
from unittest.mock import patch

os.environ.setdefault("OBJECT_SERVER_TOKEN", "test-token")
os.environ.setdefault("FALKEY", "unused-test-key")
import fal_server


class DriveStorageTests(unittest.TestCase):
    def test_separate_room_and_library_folders(self):
        with patch.object(fal_server, "DRIVE_REMOTE", "owner:RoomTwin"):
            self.assertEqual(fal_server.drive_path("user-a", "item-a", "model.usdz", "objects"),
                             "owner:RoomTwin/Users/user-a/Objects/item-a/model.usdz")
            self.assertEqual(fal_server.drive_path("user-a", "room-a", "room.usdz", "rooms"),
                             "owner:RoomTwin/Users/user-a/Rooms/room-a/room.usdz")
            self.assertEqual(fal_server.drive_path("user-a", "old-room", "room.usdz"),
                             "owner:RoomTwin/user-a/old-room/room.usdz")

    def test_rejects_traversal_and_cross_collection_files(self):
        for user, item, name, kind in [
            ("..", "item", "model.usdz", "objects"),
            ("user", "%2e%2e", "model.usdz", "objects"),
            ("user", "item", "room.usdz", "objects"),
            ("user", "item", "model.usdz", "rooms"),
        ]:
            with self.subTest((user, item, name, kind)), self.assertRaises(ValueError):
                fal_server.drive_path(user, item, name, kind)

    def test_library_upload_stream_and_delete_use_same_directory(self):
        handler = object.__new__(fal_server.make_handler())
        handler.headers = {"X-Token": fal_server.TOKEN, "Content-Length": "7"}
        handler.path = "/drive/assets/objects/user-a/item-a/model.usdz"
        handler.rfile = io.BytesIO(b"a-model")
        handler.reply = lambda status, body: status
        uploads = []
        def uploaded(stream, length, destination):
            uploads.append((stream.read(length), destination))
        with patch.object(fal_server, "DRIVE_REMOTE", "owner:RoomTwin"), \
             patch.object(fal_server, "drive_upload", side_effect=uploaded), \
             patch.object(fal_server, "drive_delete") as deleted:
            self.assertEqual(handler.route("POST"), 200)
            self.assertEqual(uploads, [(b"a-model", "owner:RoomTwin/Users/user-a/Objects/item-a/model.usdz")])
            handler.path = "/drive/assets/objects/user-a/item-a"
            self.assertEqual(handler.route("DELETE"), 200)
            deleted.assert_called_once_with("owner:RoomTwin/Users/user-a/Objects/item-a")

    def test_wrong_gateway_token_cannot_upload(self):
        handler = object.__new__(fal_server.make_handler())
        handler.headers = {"X-Token": "wrong"}
        handler.reply = lambda status, body: status
        with patch.object(fal_server, "drive_upload") as upload:
            self.assertEqual(handler.route("POST"), 403)
            upload.assert_not_called()


if __name__ == "__main__":
    unittest.main()
