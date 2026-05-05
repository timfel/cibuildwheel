from contextlib import nullcontext
from pathlib import Path

from cibuildwheel.platforms.macos import install_graalpy


def test_install_graalpy_uses_amd64_url_override(monkeypatch, tmp_path):
    seen = {}

    monkeypatch.setattr("cibuildwheel.platforms.macos.CIBW_CACHE_PATH", Path("/cache"))
    monkeypatch.setenv(
        "CIBW_GRAALPY_MACOS_AMD64_URL",
        "file:///tmp/graalpy-debug-macos-amd64.tar.gz",
    )
    monkeypatch.setattr(
        "cibuildwheel.platforms.macos.FileLock",
        lambda *_args, **_kwargs: nullcontext(),
    )
    monkeypatch.setattr(
        "cibuildwheel.platforms.macos.Path.exists",
        lambda self: str(self).endswith("/cache/graalpy-debug-macos-amd64/bin/graalpy"),
    )
    monkeypatch.setattr("cibuildwheel.platforms.macos.Path.mkdir", lambda *args, **kwargs: None)
    monkeypatch.setattr("cibuildwheel.platforms.macos.Path.unlink", lambda *args, **kwargs: None)
    monkeypatch.setattr(
        "cibuildwheel.platforms.macos.download",
        lambda url, dest: seen.update(url=url, dest=dest),
    )
    monkeypatch.setattr("cibuildwheel.platforms.macos.call", lambda *args, **kwargs: None)

    base_python = install_graalpy(
        tmp_path,
        "https://github.com/oracle/graalpython/releases/download/graal-25.0.0/graalpy-25.0.0-macos-amd64.tar.gz",
    )

    assert seen["url"] == "file:///tmp/graalpy-debug-macos-amd64.tar.gz"
    assert str(seen["dest"]).endswith("/graalpy-debug-macos-amd64.tar.gz")
    assert str(base_python).endswith("/cache/graalpy-debug-macos-amd64/bin/graalpy")
