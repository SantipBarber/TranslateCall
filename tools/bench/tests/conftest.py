def pytest_configure(config):
    config.addinivalue_line("markers", "network: needs the network and model downloads; excluded on CI")
