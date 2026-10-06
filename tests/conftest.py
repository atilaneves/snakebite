import pytest

from dubname import forget_dub_names


@pytest.fixture(autouse=True)
def delete_dub_cache_of_the_test():
    yield
    forget_dub_names()
