from setuptools import setup
from Cython.Build import cythonize

setup(
    ext_modules=cythonize([
        "agent.pyx",
        "interface.pyx",
        "procurement.pyx",
        "protocol.pyx",
        "net.pyx",
        "workers.pyx",
    ])
)
