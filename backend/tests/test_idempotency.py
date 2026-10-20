from __future__ import annotations

from flask import Flask, request

from app.errors import ApiError
from app.idempotency import build_idempotency_context


def _request(body: str, *, key: str = "req_01JAZ9PNK2ZV4T6D8X0ABCDEF1", query: str = ""):
    app = Flask(__name__)
    with app.test_request_context(
        f"/api/v1/goods-receipts/post{query}",
        method="POST",
        data=body,
        content_type="application/json",
        headers={"Idempotency-Key": key},
    ):
        request.url_rule = None
        request.view_args = {"id": "receipt-1"}
        return build_idempotency_context(request, "cd79a45a-2b9a-47a9-9e4f-7f6b25e9ec01")


def test_key_validation_and_scope():
    context = _request('{"a":1,"b":2}')
    assert context.key == "req_01JAZ9PNK2ZV4T6D8X0ABCDEF1"
    assert context.operation_scope == "POST:/api/v1/goods-receipts/post"


def test_canonical_hash_is_independent_of_json_key_order():
    first = _request('{"a":1,"b":2}')
    second = _request('{"b":2,"a":1}')
    assert first.request_hash == second.request_hash


def test_canonical_hash_changes_when_payload_changes():
    first = _request('{"a":1}')
    second = _request('{"a":2}')
    assert first.request_hash != second.request_hash


def test_key_too_short_or_invalid_characters_is_rejected():
    for invalid in ("short", "key with whitespace 123456", "unicode-é-0123456789"):
        try:
            _request('{"a":1}', key=invalid)
        except ApiError as exc:
            assert exc.code == "INVALID_IDEMPOTENCY_KEY"
        else:
            raise AssertionError("Expected invalid idempotency key to be rejected")


def test_deterministic_hash_is_sha256_hex():
    context = _request('{"message":"hello"}')
    assert len(context.request_hash) == 64
    int(context.request_hash, 16)


def test_query_string_is_part_of_hash():
    first = _request('{"a":1}', query="?page=1")
    second = _request('{"a":1}', query="?page=2")
    assert first.request_hash != second.request_hash
