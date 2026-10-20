from __future__ import annotations

from flask import Flask, g

from app.errors import ApiError
from app.idempotency import IdempotencyContext, idempotency_rpc_parameters


def test_idempotency_rpc_parameters_use_only_validated_context():
    app = Flask(__name__)
    context = IdempotencyContext(
        key="req_01JAZ9PNK2ZV4T6D8X0ABCDEF1",
        owner_id="cd79a45a-2b9a-47a9-9e4f-7f6b25e9ec01",
        operation_scope="POST:/api/v1/example",
        request_hash="a" * 64,
    )
    with app.test_request_context("/api/v1/example"):
        g.idempotency = context
        assert idempotency_rpc_parameters() == {
            "p_idempotency_key": context.key,
            "p_request_hash": context.request_hash,
        }


def test_missing_idempotency_context_fails_closed():
    app = Flask(__name__)
    with app.test_request_context("/api/v1/example"):
        try:
            idempotency_rpc_parameters()
        except ApiError as exc:
            assert exc.code == "IDEMPOTENCY_CONTEXT_MISSING"
        else:
            raise AssertionError("Missing idempotency context must not be accepted")
