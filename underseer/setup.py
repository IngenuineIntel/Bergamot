from setuptools import setup
from Cython.Build import cythonize

setup(
    ext_modules=cythonize([,
        "interface.pyx",
        "procurement.pyx",
        "protocol.pyx",
        "net.pyx",
        "underseer.pyx"
        "workers.pyx",
    ])
)
