.. _authenticate-github:

Authenticate with GitHub
========================

This guide wires your GitHub credentials into a workshop instance so ``gh``
works inside the container - without any token ever touching the
repository, the rendered YAML, or the container environment.

How the flow works
------------------

The credential never lives in the workshop definition. Instead:

1. ``just secret-setup`` stores your personal access token in the **host
   keyring** (service ``sunbeam-workshop-github-token``).
2. It logs the host ``gh`` in with that token
   (``gh auth login --with-token``), because the rendered secret slot
   reads ``gh``'s own keyring login.
3. The rendered workshop definition declares a ``system:github-token``
   secret slot carrying keyring **lookup attributes** - service
   ``gh:github.com``, username ``""`` (the account ``gh`` is currently
   using on the host) - never the token value.
4. ``workshop connect <name>/gh-cli:github-token
   <name>/system:github-token`` wires the instance's gh-cli plug to that
   slot; the gh-cli SDK then injects the token per command inside the
   workshop.

Create the token
----------------

Create a personal access token at
`https://github.com/settings/personal-access-tokens <https://github.com/settings/personal-access-tokens>`_
(see GitHub's
`creating a personal access token <https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token>`_
guide).

The token authenticates the ``gh`` CLI, so its scopes are the scopes your
own ``gh`` workflow needs: read access to the repositories you clone, and
write access for pushing to your forks. This repository does not dictate
scopes - create the token that matches your work.

Store the token and log in host ``gh``
--------------------------------------

On the host, run:

.. code-block:: sh

   just secret-setup

The recipe is guarded (``assert-host``) and refuses to run inside a
workshop container. It:

- prompts for the token with hidden input (``read -rs``) - the token is
  never printed, and reaches the keyring and ``gh`` only through stdin
  pipes;
- stores it in the host keyring under service
  ``sunbeam-workshop-github-token``, or reports the existing entry;
- runs ``gh auth login --with-token`` if the host ``gh`` is not
  authenticated yet.

Re-running is idempotent. To replace a stored token:

.. code-block:: sh

   secret-tool clear service sunbeam-workshop-github-token
   just secret-setup

Wire a workshop instance
------------------------

With the keyring populated, connect an instance's gh-cli plug:

.. code-block:: sh

   just secret-setup sunbeam

This runs ``workshop connect sunbeam/gh-cli:github-token
sunbeam/system:github-token``. The guided setup (``just setup <name>``)
wires the plug automatically once the instance reports Ready - the
instance does not exist when its secrets step first runs, so setup re-runs
the wiring after launch.

Check the wiring at any time:

.. code-block:: sh

   workshop connections sunbeam

Use ``gh`` inside the workshop
------------------------------

.. code-block:: sh

   just shell sunbeam
   gh auth status

``gh`` commands - cloning, forking, pushing to your fork over HTTPS - now
work inside the workshop with no further login.

.. warning::

   Never export ``GITHUB_TOKEN`` or ``GH_TOKEN`` in the host shell or the
   container environment. ``gh`` prefers those variables over its stored
   keyring login, so a stale or over-broad value silently overrides
   authentication and breaks standard ``gh`` commands. The secret-plug
   flow exists precisely to keep the token out of every environment.

Troubleshooting
---------------

``secret-tool`` **is not installed.**
Install it with ``sudo apt install -y libsecret-tools`` and re-run
``just secret-setup``.

**"multiple secrets match" when the secret slot is read.**
The slot looks up service ``gh:github.com`` with an empty username, which
selects the account ``gh`` is currently using on the host. Make sure
``gh auth status`` on the host shows a single healthy login.

**The plug wiring was skipped.**
``just secret-setup <name>`` skips the ``workshop connect`` step when the
instance is not launched yet. Launch it (``just setup <name>`` or
``just launch <name>``), then re-run ``just secret-setup <name>`` - the
keyring steps report already-done and only the connection is new.

``gh`` **inside the workshop is not authenticated.**
Confirm the connection exists (``workshop connections <name>``), that the
host ``gh`` is authenticated (``gh auth status`` on the host), and that no
``GITHUB_TOKEN``/``GH_TOKEN`` variable is set in the container
environment.
