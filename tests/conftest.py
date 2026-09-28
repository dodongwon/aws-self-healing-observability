import os
import sys
from dataclasses import dataclass
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]

os.environ.update(
    AWS_DEFAULT_REGION="ap-northeast-2",
    AWS_ACCESS_KEY_ID="testing",
    AWS_SECRET_ACCESS_KEY="testing",
    POWERTOOLS_SERVICE_NAME="obs-app-test",
    POWERTOOLS_METRICS_NAMESPACE="ObsApp",
    POWERTOOLS_TRACE_DISABLED="1",
)
os.environ.pop("AWS_PROFILE", None)


@dataclass
class FakeContext:
    function_name: str = "obs-app-test"
    function_version: str = "$LATEST"
    memory_limit_in_mb: int = 256
    invoked_function_arn: str = "arn:aws:lambda:ap-northeast-2:123456789012:function:obs-app-test"
    aws_request_id: str = "req-test"


@pytest.fixture
def context():
    return FakeContext()


def load_module(name: str, rel_dir: str):
    """테스트마다 모듈을 새로 import해 모킹된 boto3 클라이언트를 잡게 한다."""
    path = str(ROOT / rel_dir)
    if path not in sys.path:
        sys.path.insert(0, path)
    sys.modules.pop(name, None)
    return __import__(name)
