from setuptools import setup
from Cython.Build import cythonize

setup(
    ext_modules=cythonize([
        "underseer.pyx",
        "underseer_workers.pyx",
    ])
)
