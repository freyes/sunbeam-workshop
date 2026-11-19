.. _just-targets:

Just targets
============

``just`` is the single entry point for every workflow. Running it with no
arguments lists the available commands. Host-mutating recipes carry the
``assert-host`` guard: they refuse to run inside a workshop container, on a
non-Ubuntu host, or when no working LXD answers;
``I_KNOW_WHAT_IM_DOING=1`` bypasses the guard.

Instance lifecycle
------------------

.. list-table::
   :header-rows: 1

   * - Target
     - Effect
     - Guard
   * - ``just setup <name>``
     - Guided, idempotent six-step setup of a named instance: doctor, confirm, render, persist variables, secrets, launch and wait Ready. ``SETUP_YES=1`` takes every default.
     - ``assert-host``
   * - ``just render <name>``
     - Render ``.workshop/<name>.yaml`` from the profile template and merged variables.
     - -
   * - ``just launch <name>``
     - Launch a rendered instance (``workshop launch`` passthrough).
     - -
   * - ``just shell <name>``
     - Interactive bash shell in a running instance.
     - -
   * - ``just stop <name>``
     - Stop a running instance.
     - -
   * - ``just remove <name>``
     - Remove an instance and its container; a never-launched instance (``workshop remove`` refuses it with "not launched") is removed by dropping its rendered ``.workshop/<name>.yaml`` definition. Unrelated failures propagate unchanged.
     - -

Host and credentials
--------------------

.. list-table::
   :header-rows: 1

   * - Target
     - Effect
     - Guard
   * - ``just doctor [name]``
     - Read-only host prerequisite checks. With ``sunbeam``, additionally reports the sidecar-VM capacity floor (8 cores, 16 GiB RAM, 100 GiB disk) as warnings.
     - read-only
   * - ``just secret-setup [name]``
     - Store the GitHub token in the host keyring, log in the host ``gh``, and - with a name - wire the instance's gh-cli secret plug.
     - ``assert-host``
   * - ``just repos [profile]``
     - Clone or update the per-profile repository checkouts under ``git/`` of the repo checkout (``/project/git`` inside the workshop container; GitHub, opendev/Gerrit, Launchpad). Extra arguments pass through to the repo manager; ``--filter <glob>`` (repeatable, ORed) limits the run to matching repo names, e.g. ``just repos packaging --filter 'neutron*'``.
     - ``assert-host``

Sidecar VM (sunbeam profile)
----------------------------

.. list-table::
   :header-rows: 1

   * - Target
     - Effect
     - Guard
   * - ``just vm-create``
     - Create and provision the sidecar dev VM.
     - ``assert-host``
   * - ``just vm-destroy``
     - Revoke the LXD trust server-side and delete the VM; keeps ``.state/vm/`` unless ``PURGE=1``.
     - ``assert-host``
   * - ``just vm-status``
     - Report the sidecar VM state (read-only).
     - -
   * - ``just vm-shell``
     - Interactive SSH shell on the sidecar VM.
     - -

Development and docs
--------------------

.. list-table::
   :header-rows: 1

   * - Target
     - Effect
     - Guard
   * - ``just lint``
     - Local twin of the CI lint workflow: shellcheck (scripts, hooks, recipe bodies), the hook gate, actionlint, and config/template validation.
     - -
   * - ``just test``
     - Run every shell test suite under ``scripts/tests/``. The pytest unit tests run separately: ``cd scripts && uv run --frozen pytest -q``.
     - -
   * - ``just docs-build``
     - Build this documentation site (strict: warnings are errors).
     - -
   * - ``just docs-serve``
     - Build and serve the docs site locally.
     - -
   * - ``just docs-check``
     - Full docs battery: strict build, spelling, linkcheck, woke, vale.
     - -

Infrastructure recipes
----------------------

These exist for composition rather than direct use.

.. list-table::
   :header-rows: 1

   * - Target
     - Effect
   * - ``just`` / ``just default``
     - List all available commands.
   * - ``just assert-host``
     - Guard recipe depended on by the host-mutating recipes above.
