import sys
from unittest.mock import MagicMock

sys.modules.setdefault("boto3", MagicMock())
import handler  # noqa: E402


def test_handler_processes_records():
    handler.s3 = MagicMock()
    handler.s3.head_object.return_value = {"ContentLength": 5, "ContentType": "text/plain"}
    event = {"Records": [{"s3": {"bucket": {"name": "b"}, "object": {"key": "tickets/7/abc-my+file.txt"}}}]}
    assert handler.handler(event, None) == {"processed": 1}
    handler.s3.head_object.assert_called_once_with(Bucket="b", Key="tickets/7/abc-my file.txt")


def test_handler_empty_event():
    assert handler.handler({}, None) == {"processed": 0}
