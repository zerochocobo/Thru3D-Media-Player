"""Verify pinned DVD sources without overwriting modified source caches."""
import importlib.util
from pathlib import Path

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('disc_sources', root/'tools/environment/Prepare-BluraySources.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

if __name__ == '__main__':
    module.main('dvd')
