import pytest

from dubname import cache_entries, delete_plain_dub_names, forget_dub_names


@pytest.fixture(autouse=True)
def delete_dub_cache_of_the_test(tmp_path):
    before = cache_entries()
    try:
        yield
        plain = delete_plain_dub_names(tmp_path, before)
        if plain:
            pytest.fail(
                "A plain dub package name made a cache record that parallel "
                "tests share: " + "; ".join(plain),
                pytrace=False,
            )
    finally:
        forget_dub_names()
