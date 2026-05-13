<p align="center">
  <img src="overseer/static/bergamot_full_logo-512x512.png" alt="Bergamot Logo" width="50%">
</p>

BERGAMOT
---

![Repository commit activity](https://img.shields.io/github/commit-activity/m/IngenuineIntel/Bergamot?color=yellow)
![Repository code size](https://img.shields.io/github/languages/code-size/IngenuineIntel/Bergamot?color=green)
![Repository top lang](https://img.shields.io/github/languages/top/ingenuineintel/bergamot)
---

Bergamot is a modular, multi-machine system for deep analysis of system and program behaviors and patterns.
Via this system, performance, process, and system call information both present and past can be viewed,
filtered, and analyzed through a UI. Its components are as follows:

 - The Engine is a kernel module that hooks system calls and exfiltrates them to
 - The Agent, which compiles the data from the engine along with its own acquired information and sends it to
 - The Overseer, which runs on a separate machine on the network and hosts a Flask server, which is the system's UI.

> [!WARNING]
> Bergamot is designed for secure networks. The communications between the Agent and the Overseer are not in
> any way encrypted, and are never intended to be.

## Getting Started

### Engine Setup

To compile the Engine against your kernel:

```bash
make engine_build
```

A file `bergamot_engine.ko` will appear at completion in the top level directory. To install it:

```bash
make engine_install
```

The Agent can/will automatically load/reload the module at runtime as long as the module is installed.

### Agent Setup

To compile the Agent (with Cython and CX-Freeze):

```bash
make agent_freeze
```

This will spawn a virtual environment for the program, install its dependencies, and compile the Cython source and
freeze it into the executable `bergamot-agent`.

The Agent can run without arguments based on default values, but unless you're running the Overseer on the same machine
also at its default settings, you're going to want to pass values to the program. All values can be passed via environment
variables, and most can be passed via command line flags. All of the options for both of these can be printed by running
the program with the `-h` flag, which will print something like:

```
USAGE: ./bergamot-agent [FLAGS/VALS]

Flags:
    -c <VAL>     Host to connect to (default BERGAMOT_HOST or localhost)
    -p <VAL>     Port to connect on (default BERGAMOT_WIRE_PORT or 12046)
    -fe <VAL>    Frequency of event packets (default BERGAMOT_EVENT_HZ or 4)
    -fs <VAL>    Frequency of process snapshot packets (default BERGAMOT_PROC_HZ or 1)
    -fp <VAL>    Frequency of performance snapshot packets (default BERGAMOT_PERF_HZ or 2)
    -t <VAL>     Timeout before connection is tried again (default BERGAMOT_REC_MAX or 30)
    -h             Prints this message
```

### Overseer Setup

Since the Overseer is written in pure Python, it can be run very simply with default settings. It will wait for a
connection from the Agent at port 12046, and will start an HTTP server on port 27960. It can be started with:

```bash
make overseer_run
```

## Using the UI

Currently, this program lacks the stuff I'd be talking about (at least, the UI's not very good), nevermind consice
information about it.

## Contribution

![Who doesn't love a good flowchart?](static/contribution_guidelines.jpg)

Contribution, and interest in contribution, is greatly welcomed. More specific guidelines on contribution, as well as general
how-to's for familiarizing yourself with the codebase and how it works, ~~can be found in `CONTRIBUTING.md`.~~

## Licensing

Each component of Bergamot might have its own license. The Agent and Overseer are licensed under the MIT license, while
the Engine is licensed under the GPLv3.

> [!IMPORTANT]
> Any code contributed to this repository is, unless expressly specified by the author, licensed under the license of
> the program the code contributes to. _If you want your contribution licensed differently, **say so**_, or forever hold your peace.

## Questions or Concerns

If you have any questions about this repository or any component of it, feel free to leave an issue, or email me at 
<roan.rothrock@proton.me>.
